"use client";

import { useState, useEffect } from "react";
import { ApiDebugConsole } from "@/components/debug/ApiDebugConsole";
import { ApiTester } from "@/components/debug/ApiTester";

export default function ApiDebugDashboard() {
  const [activeTab, setActiveTab] = useState<"console" | "tester">("console");

  return (
    <div className="min-h-screen bg-gray-900 text-white">
      {/* Header */}
      <header className="bg-gray-800 border-b border-gray-700 px-6 py-4">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-blue-400">EarnLayer API Debug Console</h1>
            <p className="text-gray-400 mt-1">Real-time API monitoring and testing dashboard</p>
          </div>
          <div className="flex items-center gap-2 text-sm">
            <div className="flex items-center gap-2">
              <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
              <span className="text-green-400">Live</span>
            </div>
            <span className="text-gray-500">|</span>
            <span className="text-gray-400">api.earnlayerai.com</span>
          </div>
        </div>
      </header>

      {/* Navigation Tabs */}
      <nav className="bg-gray-800 px-6 py-3 border-b border-gray-700">
        <div className="flex gap-6">
          <button
            onClick={() => setActiveTab("console")}
            className={`px-4 py-2 rounded-lg transition-colors font-medium ${
              activeTab === "console"
                ? "bg-blue-600 text-white"
                : "text-gray-400 hover:text-white hover:bg-gray-700"
            }`}
          >
            🖥️ Console Logs
          </button>
          <button
            onClick={() => setActiveTab("tester")}
            className={`px-4 py-2 rounded-lg transition-colors font-medium ${
              activeTab === "tester"
                ? "bg-blue-600 text-white"
                : "text-gray-400 hover:text-white hover:bg-gray-700"
            }`}
          >
            🔧 API Tester
          </button>
        </div>
      </nav>

      {/* Main Content */}
      <main className="p-6">
        {activeTab === "console" && <ApiDebugConsole />}
        {activeTab === "tester" && <ApiTester />}
      </main>
    </div>
  );
}