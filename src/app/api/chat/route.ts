import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { chatSessions, chatMessages } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { embeddingService } from "@/lib/services/embeddings";
import { adServingService } from "@/lib/services/ad-serving";
import OpenAI from "openai";
import { z } from "zod";

const openai = process.env.OPENAI_API_KEY && !process.env.OPENAI_API_KEY.includes("placeholder")
  ? new OpenAI({ apiKey: process.env.OPENAI_API_KEY })
  : null;

const chatRequestSchema = z.object({
  session_id: z.string().uuid(),
  message: z.string().min(1),
  role: z.enum(["user", "assistant", "system"]).default("user"),
  include_ads: z.boolean().default(true),
  ad_preferences: z.object({
    types: z.array(z.string()).optional(),
    max_ads: z.number().min(0).max(5).default(2),
    similarity_threshold: z.number().min(0).max(1).default(0.3),
  }).optional(),
});

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const validatedData = chatRequestSchema.parse(body);

    // Verify session exists
    const session = await db
      .select()
      .from(chatSessions)
      .where(eq(chatSessions.id, validatedData.session_id))
      .limit(1);

    if (session.length === 0) {
      return NextResponse.json(
        { error: "Session not found" },
        { status: 404 }
      );
    }

    const sessionData = session[0];

    // Generate embedding for the message
    const messageEmbedding = await embeddingService.generateEmbedding(validatedData.message);

    // Store the user message
    const userMessage = await db
      .insert(chatMessages)
      .values({
        sessionId: validatedData.session_id,
        content: validatedData.message,
        role: validatedData.role,
        createdAt: new Date(),
        embedding: `[${messageEmbedding.join(",")}]` as any,
      })
      .returning();

    // Generate AI response using OpenAI
    const aiResponse = await generateAIResponse(validatedData.session_id, validatedData.message);

    // Store the AI response
    const assistantMessage = await db
      .insert(chatMessages)
      .values({
        sessionId: validatedData.session_id,
        content: aiResponse,
        role: "assistant",
        createdAt: new Date(),
        embedding: `[${(await embeddingService.generateEmbedding(aiResponse)).join(",")}]` as any,
      })
      .returning();

    // Get contextual ads if requested
    let contextualAds: any[] = [];
    if (validatedData.include_ads && sessionData.creatorId) {
      const adPrefs = validatedData.ad_preferences || {};
      
      try {
        const adResult = await adServingService.serveContextualAds(
          validatedData.message,
          {
            creatorId: sessionData.creatorId,
            sessionId: validatedData.session_id,
            limit: adPrefs.max_ads,
            similarityThreshold: adPrefs.similarity_threshold,
          }
        );

        contextualAds = adResult.ads.map(ad => ({
          id: ad.id,
          title: ad.title,
          content: ad.content,
          target_url: ad.targetUrl,
          ad_type: ad.adType,
          similarity: ad.similarity,
          impression_id: ad.impressionId,
        }));
      } catch (error) {
        console.error("Error getting contextual ads:", error);
        // Continue without ads if ad serving fails
      }
    }

    return NextResponse.json({
      session_id: validatedData.session_id,
      messages: [
        {
          id: userMessage[0].id,
          content: validatedData.message,
          role: "user",
          created_at: userMessage[0].createdAt.toISOString(),
        },
        {
          id: assistantMessage[0].id,
          content: aiResponse,
          role: "assistant",
          created_at: assistantMessage[0].createdAt.toISOString(),
        },
      ],
      contextual_ads: contextualAds,
      ads_included: validatedData.include_ads,
    });

  } catch (error) {
    console.error("Error processing chat message:", error);
    
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { 
          error: "Invalid request data", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: "Failed to process chat message" },
      { status: 500 }
    );
  }
}

// Get chat history
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const sessionId = searchParams.get('session_id');
  const limit = parseInt(searchParams.get('limit') || '50');

  if (!sessionId) {
    return NextResponse.json(
      { error: "session_id parameter is required" },
      { status: 400 }
    );
  }

  try {
    const messages = await db
      .select({
        id: chatMessages.id,
        content: chatMessages.content,
        role: chatMessages.role,
        createdAt: chatMessages.createdAt,
      })
      .from(chatMessages)
      .where(eq(chatMessages.sessionId, sessionId))
      .orderBy(chatMessages.createdAt)
      .limit(limit);

    return NextResponse.json({
      session_id: sessionId,
      messages: messages.map(msg => ({
        id: msg.id,
        content: msg.content,
        role: msg.role,
        created_at: msg.createdAt.toISOString(),
      })),
      total_messages: messages.length,
    });

  } catch (error) {
    console.error("Error getting chat history:", error);
    return NextResponse.json(
      { error: "Failed to get chat history" },
      { status: 500 }
    );
  }
}

// Generate AI response using OpenAI
async function generateAIResponse(sessionId: string, userMessage: string): Promise<string> {
  if (!openai) {
    return `Thank you for your message: "${userMessage}". This is a test response since OpenAI API key is not configured.`;
  }

  try {
    // Get recent conversation context
    const recentMessages = await db
      .select({
        content: chatMessages.content,
        role: chatMessages.role,
      })
      .from(chatMessages)
      .where(eq(chatMessages.sessionId, sessionId))
      .orderBy(chatMessages.createdAt)
      .limit(10);

    // Build conversation context
    const messages: OpenAI.Chat.Completions.ChatCompletionMessageParam[] = [
      {
        role: "system",
        content: "You are a helpful AI assistant. Provide informative and engaging responses to users' questions."
      },
      ...recentMessages.map(msg => ({
        role: msg.role as "user" | "assistant" | "system",
        content: msg.content,
      })),
      {
        role: "user",
        content: userMessage,
      },
    ];

    const completion = await openai.chat.completions.create({
      model: "gpt-3.5-turbo",
      messages,
      max_tokens: 500,
      temperature: 0.7,
    });

    return completion.choices[0]?.message?.content || "I'm sorry, I couldn't generate a response right now.";

  } catch (error) {
    console.error("Error generating AI response:", error);
    return "I'm sorry, I'm having trouble responding right now. Please try again.";
  }
}