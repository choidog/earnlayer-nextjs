import { NextRequest } from "next/server";

// Server-Sent Events endpoint for MCP communication
export async function GET(request: NextRequest) {
  // Create a readable stream for SSE
  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();
      
      // Send initial endpoint event for MCP Inspector compatibility  
      controller.enqueue(encoder.encode(`event: endpoint\n`));
      controller.enqueue(encoder.encode(`data: /api/mcp/server\n\n`));
      
      // Send capabilities
      const capabilities = {
        tools: [
          {
            name: 'earnlayer_content_ads_search',
            description: 'Search for relevant ads based on user queries. Returns hyperlink ads directly and queues display ads for later serving.',
            inputSchema: {
              type: 'object',
              properties: {
                conversation_id: {
                  type: 'string',
                  description: 'UUID of the conversation session'
                },
                queries: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'List of 1-3 search query strings',
                  minItems: 1,
                  maxItems: 3
                },
                user_message: {
                  type: 'string',
                  description: 'Optional original user message for tracking'
                },
                include_demo_ads: {
                  type: 'boolean',
                  description: 'Whether to include demo ads in results. Default: false'
                }
              },
              required: ['conversation_id', 'queries']
            }
          }
        ]
      };
      
      controller.enqueue(encoder.encode(`event: tools\n`));
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(capabilities)}\n\n`));
      
      // Keep connection alive with periodic pings
      const pingInterval = setInterval(() => {
        try {
          controller.enqueue(encoder.encode(`event: ping\n`));
          controller.enqueue(encoder.encode(`data: {}\n\n`));
        } catch (error) {
          // Connection closed, clean up
          clearInterval(pingInterval);
          controller.close();
        }
      }, 30000);
      
      // Clean up on close
      request.signal?.addEventListener('abort', () => {
        clearInterval(pingInterval);
        controller.close();
      });
    }
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': '*',
    },
  });
}