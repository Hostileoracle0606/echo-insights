import { useEffect, useRef, useState } from "react";

type SR = typeof window extends never ? never : any;

interface Options {
  onFinalChunk?: (text: string) => void;
}

export function useSpeechRecognition(opts: Options = {}) {
  const [supported, setSupported] = useState(false);
  const [listening, setListening] = useState(false);
  const [interim, setInterim] = useState("");
  const [transcript, setTranscript] = useState("");
  const [error, setError] = useState<string | null>(null);
  const recRef = useRef<SR | null>(null);
  const onFinalRef = useRef(opts.onFinalChunk);
  onFinalRef.current = opts.onFinalChunk;

  useEffect(() => {
    if (typeof window === "undefined") return;
    const SR = (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition;
    if (!SR) {
      setSupported(false);
      return;
    }
    setSupported(true);
    const rec = new SR();
    rec.continuous = true;
    rec.interimResults = true;
    rec.lang = "en-US";
    rec.onresult = (event: any) => {
      let interimText = "";
      let finalText = "";
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const res = event.results[i];
        if (res.isFinal) finalText += res[0].transcript;
        else interimText += res[0].transcript;
      }
      if (finalText) {
        setTranscript((prev) => (prev ? prev + " " + finalText.trim() : finalText.trim()));
        onFinalRef.current?.(finalText.trim());
      }
      setInterim(interimText);
    };
    rec.onerror = (e: any) => {
      if (e.error === "no-speech" || e.error === "aborted") return;
      setError(e.error || "speech error");
    };
    rec.onend = () => {
      setListening((wasListening) => {
        if (wasListening) {
          try { rec.start(); return true; } catch { return false; }
        }
        return false;
      });
    };
    recRef.current = rec;
    return () => {
      try { rec.stop(); } catch { /* ignore */ }
    };
  }, []);

  const start = () => {
    setError(null);
    if (!recRef.current) return;
    try {
      recRef.current.start();
      setListening(true);
    } catch {
      // already started
    }
  };

  const stop = () => {
    setListening(false);
    try { recRef.current?.stop(); } catch { /* ignore */ }
    setInterim("");
  };

  const reset = () => {
    setTranscript("");
    setInterim("");
    setError(null);
  };

  return { supported, listening, interim, transcript, error, start, stop, reset, setTranscript };
}
