"use client";

import { useState, useEffect, useRef } from "react";

interface LogEntry {
  id: string;
  timestamp: Date;
  level: "info" | "error" | "warning" | "debug" | "warn";
  endpoint: string;
  method?: string;
  message: string;
  details?: any;
  requestId?: string;
  statusCode?: number;
  duration?: number;
  userId?: string;
}

export function ApiDebugConsole() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filter, setFilter] = useState<"all" | "info" | "error" | "warning">("all");
  const [isAutoScroll, setIsAutoScroll] = useState(true);
  const [searchTerm, setSearchTerm] = useState("");
  const [connectionStatus, setConnectionStatus] = useState<"connecting" | "connected" | "disconnected">("connecting");
  const logsEndRef = useRef<HTMLDivElement>(null);
  const eventSourceRef = useRef<EventSource | null>(null);

  // Real-time log streaming via SSE
  useEffect(() => {
    const connectToLogStream = () => {
      setConnectionStatus("connecting");
      
      // Build URL with filters
      const params = new URLSearchParams();
      if (filter !== "all") {
        params.set("level", filter);
      }
      
      const url = `/api/logs/stream${params.toString() ? `?${params.toString()}` : ''}`;
      const eventSource = new EventSource(url);
      eventSourceRef.current = eventSource;

      eventSource.onopen = () => {
        console.log("✅ Connected to log stream");
        setConnectionStatus("connected");
      };

      eventSource.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          
          if (data.type === 'connected') {
            console.log("📡 Log stream connection established");
            return;
          }
          
          if (data.type === 'log') {
            const logEntry: LogEntry = {
              id: data.id,
              timestamp: new Date(data.timestamp),
              level: data.level === 'warn' ? 'warning' : data.level,
              endpoint: data.endpoint,
              method: data.method,
              message: data.message,
              details: data.details,
              requestId: data.requestId,
              statusCode: data.statusCode,
              duration: data.duration,
              userId: data.userId,
            };

            setLogs(prev => {
              // Prevent duplicates and keep last 200 logs
              const filtered = prev.filter(log => log.id !== logEntry.id);
              return [...filtered.slice(-199), logEntry];
            });
          }
          
          if (data.type === 'error') {
            console.error("❌ Log stream error:", data.message);
          }
        } catch (error) {
          console.error("Failed to parse SSE message:", error);
        }
      };

      eventSource.onerror = (error) => {
        console.error("❌ Log stream connection error:", error);
        setConnectionStatus("disconnected");
        
        // Attempt to reconnect after 5 seconds
        setTimeout(() => {
          if (eventSourceRef.current?.readyState === EventSource.CLOSED) {
            connectToLogStream();
          }
        }, 5000);
      };
    };

    connectToLogStream();

    return () => {
      if (eventSourceRef.current) {
        eventSourceRef.current.close();
        eventSourceRef.current = null;
      }
    };
  }, [filter]); // Reconnect when filter changes

  // Auto scroll to bottom
  useEffect(() => {
    if (isAutoScroll) {
      logsEndRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [logs, isAutoScroll]);

  const filteredLogs = logs.filter(log => {
    const matchesFilter = filter === "all" || log.level === filter;
    const matchesSearch = searchTerm === "" || 
      log.message.toLowerCase().includes(searchTerm.toLowerCase()) ||
      log.endpoint.toLowerCase().includes(searchTerm.toLowerCase());
    return matchesFilter && matchesSearch;
  });

  const getLevelColor = (level: string) => {
    switch (level) {
      case "error": return "text-red-400";
      case "warning": return "text-yellow-400";
      case "info": return "text-blue-400";
      case "debug": return "text-gray-400";
      default: return "text-gray-300";
    }
  };

  const getStatusColor = (statusCode?: number) => {
    if (!statusCode) return "text-gray-400";
    if (statusCode >= 200 && statusCode < 300) return "text-green-400";
    if (statusCode >= 400 && statusCode < 500) return "text-yellow-400";
    if (statusCode >= 500) return "text-red-400";
    return "text-gray-400";
  };

  return (
    <div className="bg-gray-800 rounded-lg border border-gray-700">
      {/* Controls */}
      <div className="p-4 border-b border-gray-700 flex flex-wrap gap-4 items-center justify-between">
        <div className="flex gap-4 items-center">
          <div className="flex gap-2">
            <button
              onClick={() => setFilter("all")}
              className={`px-3 py-1 text-sm rounded ${filter === "all" ? "bg-blue-600 text-white" : "bg-gray-700 text-gray-300"}`}
            >
              All
            </button>
            <button
              onClick={() => setFilter("info")}
              className={`px-3 py-1 text-sm rounded ${filter === "info" ? "bg-blue-600 text-white" : "bg-gray-700 text-gray-300"}`}
            >
              Info
            </button>
            <button
              onClick={() => setFilter("warning")}
              className={`px-3 py-1 text-sm rounded ${filter === "warning" ? "bg-yellow-600 text-white" : "bg-gray-700 text-gray-300"}`}
            >
              Warning
            </button>
            <button
              onClick={() => setFilter("error")}
              className={`px-3 py-1 text-sm rounded ${filter === "error" ? "bg-red-600 text-white" : "bg-gray-700 text-gray-300"}`}
            >
              Error
            </button>
          </div>
          
          <div className="flex items-center gap-2">
            <input
              type="text"
              placeholder="Search logs..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="px-3 py-1 text-sm bg-gray-700 text-white rounded border border-gray-600 focus:border-blue-500 focus:outline-none"
            />
          </div>
        </div>

        <div className="flex gap-4 items-center">
          <div className="flex items-center gap-2 text-sm">
            <div className={`w-2 h-2 rounded-full ${
              connectionStatus === 'connected' ? 'bg-green-500 animate-pulse' :
              connectionStatus === 'connecting' ? 'bg-yellow-500 animate-pulse' :
              'bg-red-500'
            }`}></div>
            <span className={
              connectionStatus === 'connected' ? 'text-green-400' :
              connectionStatus === 'connecting' ? 'text-yellow-400' :
              'text-red-400'
            }>
              {connectionStatus === 'connected' ? 'Live' :
               connectionStatus === 'connecting' ? 'Connecting...' :
               'Disconnected'}
            </span>
          </div>
          
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={isAutoScroll}
              onChange={(e) => setIsAutoScroll(e.target.checked)}
              className="rounded"
            />
            Auto-scroll
          </label>
          
          <button
            onClick={() => setLogs([])}
            className="px-3 py-1 text-sm bg-red-600 text-white rounded hover:bg-red-700"
          >
            Clear Logs
          </button>
          
          <div className="text-sm text-gray-400">
            {filteredLogs.length} / {logs.length} logs
          </div>
        </div>
      </div>

      {/* Logs */}
      <div className="h-96 overflow-y-auto font-mono text-sm">
        {filteredLogs.map((log) => (
          <div
            key={log.id}
            className="px-4 py-2 border-b border-gray-700/50 hover:bg-gray-700/30 transition-colors"
          >
            <div className="flex items-start gap-4">
              <div className="text-gray-500 text-xs min-w-[100px]">
                {log.timestamp.toLocaleTimeString()}
              </div>
              
              <div className={`text-xs font-bold uppercase min-w-[60px] ${getLevelColor(log.level)}`}>
                {log.level}
              </div>
              
              <div className="text-purple-400 text-xs min-w-[200px] truncate">
                {log.endpoint}
              </div>
              
              <div className="flex-1 text-gray-300">
                {log.message}
              </div>
              
              <div className="flex gap-4 text-xs">
                {log.statusCode && (
                  <span className={getStatusColor(log.statusCode)}>
                    {log.statusCode}
                  </span>
                )}
                {log.duration && (
                  <span className="text-gray-500">
                    {log.duration}ms
                  </span>
                )}
                {log.requestId && (
                  <span className="text-gray-500">
                    {log.requestId}
                  </span>
                )}
              </div>
            </div>
            
            {log.details && (
              <div className="mt-2 ml-[280px] text-xs text-gray-400 bg-gray-900/50 p-2 rounded">
                <pre>{JSON.stringify(log.details, null, 2)}</pre>
              </div>
            )}
          </div>
        ))}
        
        {filteredLogs.length === 0 && (
          <div className="p-8 text-center text-gray-500">
            No logs match the current filter
          </div>
        )}
        
        <div ref={logsEndRef} />
      </div>
    </div>
  );
}