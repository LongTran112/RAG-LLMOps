"use client";

import { FormEvent, useState } from "react";

type AnswerMode = "fast" | "complex";
type MessageRole = "user" | "assistant";

type Source = {
  content_preview?: string;
  metadata?: {
    source?: string;
    chunk_index?: number;
    page?: number;
    score?: number;
  };
};

type LlmMeta = {
  model_used?: string;
  fallback?: boolean;
  attempts?: number;
};

type StreamEvent = {
  type?: "sources" | "thinking" | "token" | "done" | "error";
  t?: string;
  sources?: Source[];
  message?: string;
};

type Message = {
  id: string;
  role: MessageRole;
  content: string;
  completed?: boolean;
  answerMode?: AnswerMode;
  thinking?: string;
  sources?: Source[];
  llm?: LlmMeta;
  error?: string;
};

const BACKEND_URL =
  process.env.NEXT_PUBLIC_RAG_BACKEND_URL?.replace(/\/$/, "") ?? "http://127.0.0.1:8000";

export default function Home() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [answerMode, setAnswerMode] = useState<AnswerMode>("fast");
  const [stream, setStream] = useState(true);
  const [isRunning, setIsRunning] = useState(false);

  const updateAssistant = (id: string, patch: Partial<Message>) => {
    setMessages((prev) =>
      prev.map((msg) => (msg.id === id ? { ...msg, ...patch } : msg))
    );
  };

  const runSync = async (assistantMessageId: string, question: string) => {
    const response = await fetch(`${BACKEND_URL}/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query: question, answer_mode: answerMode }),
    });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data?.detail || `HTTP ${response.status}`);
    }
    updateAssistant(assistantMessageId, {
      content: data.answer || "No answer returned.",
      sources: data.sources || [],
      llm: data.llm || undefined,
      completed: true,
    });
  };

  const runStream = async (assistantMessageId: string, question: string) => {
    const response = await fetch(`${BACKEND_URL}/query/stream`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query: question, answer_mode: answerMode }),
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || `HTTP ${response.status}`);
    }
    if (!response.body) {
      throw new Error("Missing response body for stream.");
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let answer = "";
    let thinking = "";
    let sources: Source[] = [];

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const events = buffer.split("\n\n");
      buffer = events.pop() || "";

      for (const event of events) {
        const line = event
          .split("\n")
          .map((l) => l.trim())
          .find((l) => l.startsWith("data: "));
        if (!line) continue;
        const raw = line.slice(6);
        let payload: StreamEvent;
        try {
          payload = JSON.parse(raw);
        } catch {
          continue;
        }

        if (payload.type === "sources") {
          sources = payload.sources || [];
          updateAssistant(assistantMessageId, { sources });
          continue;
        }
        if (payload.type === "thinking") {
          thinking += payload.t || "";
          updateAssistant(assistantMessageId, { thinking });
          continue;
        }
        if (payload.type === "token") {
          answer += payload.t || "";
          updateAssistant(assistantMessageId, { content: answer });
          continue;
        }
        if (payload.type === "error") {
          throw new Error(payload.message || "Streaming error");
        }
      }
    }
    updateAssistant(assistantMessageId, { completed: true });
  };

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault();
    const question = input.trim();
    if (!question || isRunning) return;

    const userMessage: Message = {
      id: `user-${Date.now()}`,
      role: "user",
      content: question,
    };
    const assistantMessage: Message = {
      id: `assistant-${Date.now()}`,
      role: "assistant",
      content: "",
      completed: false,
      answerMode,
      thinking: "",
      sources: [],
    };
    setMessages((prev) => [...prev, userMessage, assistantMessage]);
    setInput("");
    setIsRunning(true);

    try {
      if (stream) {
        await runStream(assistantMessage.id, question);
      } else {
        await runSync(assistantMessage.id, question);
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Request failed.";
      updateAssistant(assistantMessage.id, {
        error: message,
        completed: true,
        content: "The request failed. Check backend connectivity and try again.",
      });
    } finally {
      setIsRunning(false);
    }
  };

  return (
    <main className="chatShell">
      <header className="chatHeader">
        <h1>RAG Thesis Chat (Next.js)</h1>
        <p>Thinking stream in grayscale, answers normal, sources collapsible.</p>
      </header>

      <section className="modeBar">
        <div className="modeGroup">
          <button
            type="button"
            className={answerMode === "fast" ? "modeBtn active" : "modeBtn"}
            onClick={() => setAnswerMode("fast")}
            disabled={isRunning}
          >
            Fast
          </button>
          <button
            type="button"
            className={answerMode === "complex" ? "modeBtn active" : "modeBtn"}
            onClick={() => setAnswerMode("complex")}
            disabled={isRunning}
          >
            Complex
          </button>
        </div>
        <label className="streamToggle">
          <input
            type="checkbox"
            checked={stream}
            onChange={(e) => setStream(e.target.checked)}
            disabled={isRunning}
          />
          Stream
        </label>
      </section>

      <section className="chatBody">
        {messages.length === 0 && (
          <div className="emptyState">
            Ask a question to start. Complex mode shows live reasoning in grayscale.
          </div>
        )}

        {messages.map((msg) => (
          <article key={msg.id} className={`msg ${msg.role}`}>
            <div className="msgMeta">{msg.role === "user" ? "You" : "Assistant"}</div>

            {msg.role === "assistant" && msg.answerMode === "complex" && msg.thinking && (
              <div className="thinkingBox">
                <div className="thinkingTitle">Thinking</div>
                <pre>{msg.thinking}</pre>
              </div>
            )}

            <div className="msgContent">{msg.content || (msg.role === "assistant" ? "..." : "")}</div>

            {msg.error && <div className="errorText">{msg.error}</div>}

            {msg.role === "assistant" && msg.completed && msg.sources && msg.sources.length > 0 && (
              <details className="sourcesPanel">
                <summary>Sources ({msg.sources.length})</summary>
                {msg.sources.map((source, index) => (
                  <div className="sourceCard" key={`${msg.id}-source-${index}`}>
                    <div className="sourceTitle">
                      {source.metadata?.source || "Unknown source"}
                    </div>
                    <div className="sourceMeta">
                      <span>Page: {source.metadata?.page ?? "-"}</span>
                      <span>Chunk: {source.metadata?.chunk_index ?? "-"}</span>
                      <span>Score: {source.metadata?.score ?? "-"}</span>
                    </div>
                    <p>{source.content_preview || ""}</p>
                  </div>
                ))}
              </details>
            )}
          </article>
        ))}
      </section>

      <form className="chatInputBar" onSubmit={onSubmit}>
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ask about the SEC filings dataset..."
          rows={3}
          disabled={isRunning}
        />
        <button type="submit" disabled={isRunning || !input.trim()}>
          {isRunning ? "Running..." : "Send"}
        </button>
      </form>
    </main>
  );
}
