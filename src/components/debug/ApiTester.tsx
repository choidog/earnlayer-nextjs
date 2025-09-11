"use client";

import { useState } from "react";

interface TestResult {
  id: string;
  timestamp: Date;
  endpoint: string;
  method: string;
  status: number;
  statusText: string;
  responseTime: number;
  requestHeaders: Record<string, string>;
  responseHeaders: Record<string, string>;
  requestBody?: string;
  responseBody: string;
  error?: string;
}

export function ApiTester() {
  const [endpoint, setEndpoint] = useState("/api/mcp/server");
  const [method, setMethod] = useState<"GET" | "POST" | "PUT" | "DELETE">("POST");
  const [apiKey, setApiKey] = useState("");
  const [requestBody, setRequestBody] = useState('{\n  "messages": [\n    {\n      "role": "user",\n      "content": "Hello, test message"\n    }\n  ]\n}');
  const [customHeaders, setCustomHeaders] = useState('{\n  "Content-Type": "application/json"\n}');
  const [isLoading, setIsLoading] = useState(false);
  const [results, setResults] = useState<TestResult[]>([]);

  const predefinedEndpoints = [
    { 
      value: "/api/mcp/server", 
      label: "MCP Server - List Tools", 
      method: "POST",
      requestTemplate: '{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "method": "tools/list"\n}'
    },
    { 
      value: "/api/mcp/server", 
      label: "MCP Server - Call Tool", 
      method: "POST",
      requestTemplate: '{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "method": "tools/call",\n  "params": {\n    "name": "earnlayer_content_ads_search",\n    "arguments": {\n      "conversation_id": "550e8400-e29b-41d4-a716-446655440000",\n      "queries": ["test query"],\n      "user_message": "Hello, test message"\n    }\n  }\n}'
    },
    { 
      value: "/api/mcp/server", 
      label: "MCP Server - Ping", 
      method: "POST",
      requestTemplate: '{\n  "jsonrpc": "2.0",\n  "id": 1,\n  "method": "ping"\n}'
    },
    { 
      value: "/api/ads/display", 
      label: "Ad Display", 
      method: "GET",
      requestTemplate: ''
    },
    { 
      value: "/api/ads/impressions", 
      label: "Ad Impressions", 
      method: "POST",
      requestTemplate: '{\n  "adId": "example-ad-id",\n  "impressionType": "view"\n}'
    },
    { 
      value: "/api/chat/stream", 
      label: "Chat Stream", 
      method: "POST",
      requestTemplate: '{\n  "messages": [\n    {\n      "role": "user",\n      "content": "Hello, test message"\n    }\n  ]\n}'
    },
    { 
      value: "/api/conversations/initialize", 
      label: "Initialize Conversation", 
      method: "POST",
      requestTemplate: '{\n  "userId": "example-user-id"\n}'
    },
    { 
      value: "/api/debug/generate-api-key", 
      label: "Generate API Key (Debug)", 
      method: "POST",
      requestTemplate: '{}'
    },
    { 
      value: "/api/debug/test-api-key", 
      label: "Test API Key", 
      method: "POST",
      requestTemplate: '{\n  "apiKey": "your-api-key-to-test"\n}'
    }
  ];

  const handleEndpointChange = (newEndpoint: string, selectedLabel?: string) => {
    setEndpoint(newEndpoint);
    const preset = predefinedEndpoints.find(p => 
      p.value === newEndpoint && (selectedLabel ? p.label === selectedLabel : true)
    );
    if (preset) {
      setMethod(preset.method as "GET" | "POST" | "PUT" | "DELETE");
      if (preset.requestTemplate) {
        setRequestBody(preset.requestTemplate);
      }
    }
  };

  const executeRequest = async () => {
    setIsLoading(true);
    const startTime = Date.now();
    
    try {
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
      };

      if (apiKey) {
        headers["Authorization"] = `Bearer ${apiKey}`;
      }

      try {
        const parsedCustomHeaders = JSON.parse(customHeaders);
        Object.assign(headers, parsedCustomHeaders);
      } catch (e) {
        console.warn("Invalid custom headers JSON, using defaults");
      }

      const options: RequestInit = {
        method,
        headers,
      };

      if (method !== "GET" && requestBody.trim()) {
        options.body = requestBody;
      }

      const response = await fetch(`${window.location.origin}${endpoint}`, options);
      const endTime = Date.now();
      
      let responseBody = "";
      const contentType = response.headers.get("content-type");
      
      try {
        // First check if there's actually content to read
        const responseText = await response.text();
        
        if (responseText.trim() === "") {
          responseBody = "(Empty response body)";
        } else if (contentType?.includes("application/json")) {
          // Try to parse as JSON and format it
          try {
            const jsonResponse = JSON.parse(responseText);
            responseBody = JSON.stringify(jsonResponse, null, 2);
          } catch (jsonError) {
            // If JSON parsing fails, show the raw text
            responseBody = responseText;
          }
        } else {
          responseBody = responseText;
        }
      } catch (readError) {
        responseBody = `(Error reading response: ${readError instanceof Error ? readError.message : 'Unknown error'})`;
      }

      const responseHeaders: Record<string, string> = {};
      response.headers.forEach((value, key) => {
        responseHeaders[key] = value;
      });

      const result: TestResult = {
        id: Date.now().toString(),
        timestamp: new Date(),
        endpoint,
        method,
        status: response.status,
        statusText: response.statusText,
        responseTime: endTime - startTime,
        requestHeaders: headers,
        responseHeaders,
        requestBody: method !== "GET" ? requestBody : undefined,
        responseBody,
      };

      setResults(prev => [result, ...prev.slice(0, 9)]); // Keep last 10 results
    } catch (error) {
      const endTime = Date.now();
      
      const result: TestResult = {
        id: Date.now().toString(),
        timestamp: new Date(),
        endpoint,
        method,
        status: 0,
        statusText: "Network Error",
        responseTime: endTime - startTime,
        requestHeaders: {},
        responseHeaders: {},
        requestBody: method !== "GET" ? requestBody : undefined,
        responseBody: "",
        error: error instanceof Error ? error.message : "Unknown error",
      };

      setResults(prev => [result, ...prev.slice(0, 9)]);
    } finally {
      setIsLoading(false);
    }
  };

  const getStatusColor = (status: number) => {
    if (status >= 200 && status < 300) return "text-green-400";
    if (status >= 400 && status < 500) return "text-yellow-400";
    if (status >= 500) return "text-red-400";
    return "text-gray-400";
  };

  return (
    <div className="space-y-6">
      {/* Request Configuration */}
      <div className="bg-gray-800 rounded-lg border border-gray-700 p-6">
        <h3 className="text-lg font-semibold mb-4 text-blue-400">API Request Configuration</h3>
        
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Left Column */}
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-2">
                Endpoint
              </label>
              <div className="flex gap-2">
                <select
                  value={`${endpoint}|||${predefinedEndpoints.find(p => p.value === endpoint)?.label || ''}`}
                  onChange={(e) => {
                    const [selectedEndpoint, selectedLabel] = e.target.value.split('|||');
                    handleEndpointChange(selectedEndpoint, selectedLabel);
                  }}
                  className="flex-1 px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none"
                >
                  {predefinedEndpoints.map((ep, index) => (
                    <option key={`${ep.value}-${index}`} value={`${ep.value}|||${ep.label}`}>
                      {ep.label}
                    </option>
                  ))}
                </select>
                <input
                  type="text"
                  value={endpoint}
                  onChange={(e) => setEndpoint(e.target.value)}
                  className="flex-1 px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none font-mono text-sm"
                  placeholder="/api/your-endpoint"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-300 mb-2">
                  Method
                </label>
                <select
                  value={method}
                  onChange={(e) => setMethod(e.target.value as "GET" | "POST" | "PUT" | "DELETE")}
                  className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none"
                >
                  <option value="GET">GET</option>
                  <option value="POST">POST</option>
                  <option value="PUT">PUT</option>
                  <option value="DELETE">DELETE</option>
                </select>
              </div>
              
              <div>
                <label className="block text-sm font-medium text-gray-300 mb-2">
                  API Key
                </label>
                <input
                  type="password"
                  value={apiKey}
                  onChange={(e) => setApiKey(e.target.value)}
                  className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none font-mono text-sm"
                  placeholder="your-api-key"
                />
              </div>
            </div>
          </div>

          {/* Right Column */}
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-300 mb-2">
                Custom Headers (JSON)
              </label>
              <textarea
                value={customHeaders}
                onChange={(e) => setCustomHeaders(e.target.value)}
                className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none font-mono text-sm"
                rows={4}
                placeholder='{"Content-Type": "application/json"}'
              />
            </div>
          </div>
        </div>

        {method !== "GET" && (
          <div className="mt-4">
            <div className="flex items-center justify-between mb-2">
              <label className="block text-sm font-medium text-gray-300">
                Request Body (JSON)
              </label>
              {endpoint === "/api/mcp/server" && (
                <span className="text-xs text-blue-400 bg-blue-900/30 px-2 py-1 rounded">
                  💡 MCP uses JSON-RPC format
                </span>
              )}
            </div>
            <textarea
              value={requestBody}
              onChange={(e) => setRequestBody(e.target.value)}
              className="w-full px-3 py-2 bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none font-mono text-sm"
              rows={8}
              placeholder='{"key": "value"}'
            />
          </div>
        )}

        <div className="mt-6 flex justify-between items-center">
          <button
            onClick={executeRequest}
            disabled={isLoading}
            className="px-6 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {isLoading ? (
              <>
                <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                Sending...
              </>
            ) : (
              <>
                🚀 Send Request
              </>
            )}
          </button>
          
          <button
            onClick={() => setResults([])}
            className="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700"
          >
            Clear Results
          </button>
        </div>
      </div>

      {/* Results */}
      <div className="bg-gray-800 rounded-lg border border-gray-700">
        <div className="p-4 border-b border-gray-700 flex items-center justify-between">
          <h3 className="text-lg font-semibold text-blue-400">Test Results</h3>
          <div className="text-sm text-gray-400">
            {results.length} result{results.length !== 1 ? 's' : ''}
          </div>
        </div>
        
        <div className="max-h-96 overflow-y-auto">
          {results.length === 0 ? (
            <div className="p-8 text-center text-gray-500">
              No test results yet. Send a request to see results here.
            </div>
          ) : (
            results.map((result) => (
              <div
                key={result.id}
                className="p-4 border-b border-gray-700/50 hover:bg-gray-700/30 transition-colors"
              >
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-4">
                    <span className="text-xs text-gray-500">
                      {result.timestamp.toLocaleTimeString()}
                    </span>
                    <span className="px-2 py-1 bg-gray-700 text-xs rounded font-mono">
                      {result.method}
                    </span>
                    <span className="text-sm text-purple-400 font-mono">
                      {result.endpoint}
                    </span>
                  </div>
                  <div className="flex items-center gap-4 text-xs">
                    <span className={`font-bold ${getStatusColor(result.status)}`}>
                      {result.status} {result.statusText}
                    </span>
                    <span className="text-gray-500">
                      {result.responseTime}ms
                    </span>
                  </div>
                </div>
                
                {result.error && (
                  <div className="mb-3 p-3 bg-red-900/30 border border-red-700 rounded">
                    <div className="text-red-400 font-semibold text-sm mb-1">Error</div>
                    <div className="text-red-300 text-sm font-mono">{result.error}</div>
                  </div>
                )}
                
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 text-xs">
                  {result.responseBody && (
                    <div>
                      <div className="text-gray-400 font-semibold mb-2">Response Body</div>
                      <div className="bg-gray-900/50 p-3 rounded border max-h-40 overflow-y-auto">
                        <pre className="text-gray-300 font-mono whitespace-pre-wrap">
                          {result.responseBody}
                        </pre>
                      </div>
                    </div>
                  )}
                  
                  <div>
                    <div className="text-gray-400 font-semibold mb-2">Response Headers</div>
                    <div className="bg-gray-900/50 p-3 rounded border max-h-40 overflow-y-auto">
                      <pre className="text-gray-300 font-mono">
                        {JSON.stringify(result.responseHeaders, null, 2)}
                      </pre>
                    </div>
                  </div>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}