import OpenAI from "openai";

const openai = process.env.OPENAI_API_KEY && !process.env.OPENAI_API_KEY.includes("placeholder") 
  ? new OpenAI({ apiKey: process.env.OPENAI_API_KEY })
  : null;

export class EmbeddingService {
  private static instance: EmbeddingService;
  private readonly model = "text-embedding-3-small"; // 1536 dimensions, cost-effective
  private readonly maxTokens = 8192; // Token limit for embeddings

  static getInstance(): EmbeddingService {
    if (!this.instance) {
      this.instance = new EmbeddingService();
    }
    return this.instance;
  }

  /**
   * Generate embedding for a single text
   */
  async generateEmbedding(text: string): Promise<number[]> {
    if (!openai) {
      console.warn("OpenAI API key not configured, returning mock embedding");
      // Return mock 1536-dimension embedding for testing
      return new Array(1536).fill(0).map(() => Math.random() * 0.1);
    }

    try {
      // Truncate text if too long
      const truncatedText = this.truncateText(text);
      
      const response = await openai.embeddings.create({
        model: this.model,
        input: truncatedText,
        encoding_format: "float",
      });

      return response.data[0].embedding;
    } catch (error) {
      console.error("Error generating embedding:", error);
      throw new Error(`Failed to generate embedding: ${error}`);
    }
  }

  /**
   * Generate embeddings for multiple texts (batch processing)
   */
  async generateEmbeddings(texts: string[]): Promise<number[][]> {
    if (!openai) {
      console.warn("OpenAI API key not configured, returning mock embeddings");
      return texts.map(() => new Array(1536).fill(0).map(() => Math.random() * 0.1));
    }

    try {
      // Truncate all texts
      const truncatedTexts = texts.map(text => this.truncateText(text));
      
      const response = await openai.embeddings.create({
        model: this.model,
        input: truncatedTexts,
        encoding_format: "float",
      });

      return response.data.map(item => item.embedding);
    } catch (error) {
      console.error("Error generating batch embeddings:", error);
      throw new Error(`Failed to generate batch embeddings: ${error}`);
    }
  }

  /**
   * Generate embedding for ad content (title + content combined)
   */
  async generateAdEmbedding(title: string, content: string): Promise<number[]> {
    const combinedText = `${title}\n\n${content}`;
    return this.generateEmbedding(combinedText);
  }

  /**
   * Generate embedding for chat message
   */
  async generateMessageEmbedding(message: string): Promise<number[]> {
    return this.generateEmbedding(message);
  }

  /**
   * Truncate text to fit within token limits
   */
  private truncateText(text: string): string {
    // Simple approximation: ~4 characters per token
    const maxChars = this.maxTokens * 4;
    
    if (text.length <= maxChars) {
      return text;
    }

    // Truncate and add ellipsis
    return text.substring(0, maxChars - 3) + "...";
  }

  /**
   * Calculate cosine similarity between two embeddings
   */
  static cosineSimilarity(a: number[], b: number[]): number {
    if (a.length !== b.length) {
      throw new Error("Embeddings must have the same dimensions");
    }

    let dotProduct = 0;
    let normA = 0;
    let normB = 0;

    for (let i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
  }

  /**
   * Batch process large arrays with rate limiting
   */
  async processBatch<T>(
    items: T[],
    processor: (item: T) => Promise<number[]>,
    batchSize: number = 100,
    delayMs: number = 1000
  ): Promise<number[][]> {
    const results: number[][] = [];
    
    for (let i = 0; i < items.length; i += batchSize) {
      const batch = items.slice(i, i + batchSize);
      console.log(`Processing batch ${Math.floor(i/batchSize) + 1}/${Math.ceil(items.length/batchSize)}`);
      
      const batchResults = await Promise.all(
        batch.map(item => processor(item))
      );
      
      results.push(...batchResults);
      
      // Rate limiting delay
      if (i + batchSize < items.length) {
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
    }
    
    return results;
  }
}

// Export singleton instance
export const embeddingService = EmbeddingService.getInstance();