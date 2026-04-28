import { useCallback, useEffect, useRef, useState } from "react";

type MicPermissionState = PermissionState | "unknown" | "unsupported";

type SpeechRecognitionAlternativeLike = {
  transcript: string;
};

type SpeechRecognitionResultLike = {
  isFinal: boolean;
  [index: number]: SpeechRecognitionAlternativeLike;
};

type SpeechRecognitionEventLike = {
  resultIndex: number;
  results: {
    length: number;
    [index: number]: SpeechRecognitionResultLike;
  };
};

type SpeechRecognitionErrorEventLike = {
  error: string;
};

type SpeechRecognitionLike = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: SpeechRecognitionEventLike) => void) | null;
  onerror: ((event: SpeechRecognitionErrorEventLike) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
};

type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

type WindowWithSpeechRecognition = Window &
  typeof globalThis & {
    SpeechRecognition?: SpeechRecognitionConstructor;
    webkitSpeechRecognition?: SpeechRecognitionConstructor;
  };

interface Options {
  onFinalChunk?: (text: string) => void;
  onSilence?: () => void;
  silenceMs?: number;
}

function friendlySpeechError(code: string) {
  if (code === "not-allowed" || code === "service-not-allowed") {
    return "Microphone permission is blocked. Allow microphone access for this page, then try again.";
  }
  if (code === "audio-capture")
    return "No microphone was found. Check your input device and try again.";
  if (code === "network")
    return "Speech recognition is having network trouble. Try again in a moment.";
  return code || "Speech recognition could not start.";
}

export function useSpeechRecognition(opts: Options = {}) {
  const [supported, setSupported] = useState(false);
  const [listening, setListening] = useState(false);
  const [interim, setInterim] = useState("");
  const [transcript, setTranscript] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [permissionState, setPermissionState] = useState<MicPermissionState>("unknown");
  const recRef = useRef<SpeechRecognitionLike | null>(null);
  const onFinalRef = useRef(opts.onFinalChunk);
  const onSilenceRef = useRef(opts.onSilence);
  const silenceMsRef = useRef(opts.silenceMs ?? 1600);
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const listeningRef = useRef(false);
  onFinalRef.current = opts.onFinalChunk;
  onSilenceRef.current = opts.onSilence;
  silenceMsRef.current = opts.silenceMs ?? 1600;

  const armSilence = () => {
    if (silenceTimerRef.current) clearTimeout(silenceTimerRef.current);
    silenceTimerRef.current = setTimeout(() => {
      if (listeningRef.current) onSilenceRef.current?.();
    }, silenceMsRef.current);
  };

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) clearTimeout(silenceTimerRef.current);
  }, []);

  const markStopped = useCallback(() => {
    setListening(false);
    listeningRef.current = false;
    clearSilenceTimer();
  }, [clearSilenceTimer]);

  const requestMicrophoneAccess = async () => {
    if (typeof navigator === "undefined") return true;
    if (!navigator.mediaDevices?.getUserMedia) {
      setPermissionState("unsupported");
      return true;
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((track) => track.stop());
      setPermissionState("granted");
      return true;
    } catch (accessError) {
      markStopped();
      if (accessError instanceof DOMException) {
        if (accessError.name === "NotAllowedError" || accessError.name === "SecurityError") {
          setPermissionState("denied");
          setError(
            "Microphone permission is blocked. Allow microphone access for this page, then try again.",
          );
          return false;
        }
        if (accessError.name === "NotFoundError") {
          setError("No microphone was found. Check your input device and try again.");
          return false;
        }
      }
      setError("Microphone access failed. Check browser permissions and try again.");
      return false;
    }
  };

  useEffect(() => {
    if (typeof window === "undefined") return;
    const browserWindow = window as WindowWithSpeechRecognition;
    const SR = browserWindow.SpeechRecognition || browserWindow.webkitSpeechRecognition;
    if (!SR) {
      setSupported(false);
      return;
    }
    setSupported(true);
    const rec = new SR();
    rec.continuous = true;
    rec.interimResults = true;
    rec.lang = "en-US";
    rec.onresult = (event) => {
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
      // Any speech activity (interim or final) re-arms the silence timer
      if (finalText || interimText) armSilence();
    };
    rec.onerror = (e) => {
      if (e.error === "no-speech" || e.error === "aborted") return;
      if (e.error === "not-allowed" || e.error === "service-not-allowed") {
        setPermissionState("denied");
        markStopped();
      }
      if (e.error === "audio-capture") markStopped();
      setError(friendlySpeechError(e.error));
    };
    rec.onend = () => {
      setListening((wasListening) => {
        if (wasListening) {
          try {
            rec.start();
            return true;
          } catch {
            listeningRef.current = false;
            return false;
          }
        }
        return false;
      });
    };
    recRef.current = rec;
    return () => {
      try {
        rec.stop();
      } catch {
        /* ignore */
      }
    };
  }, [markStopped]);

  useEffect(() => {
    if (typeof navigator === "undefined" || !navigator.permissions?.query) return;
    let permissionStatus: PermissionStatus | null = null;
    let mounted = true;

    navigator.permissions
      .query({ name: "microphone" as PermissionName })
      .then((status) => {
        if (!mounted) return;
        permissionStatus = status;
        setPermissionState(status.state);
        status.onchange = () => setPermissionState(status.state);
      })
      .catch(() => setPermissionState("unknown"));

    return () => {
      mounted = false;
      if (permissionStatus) permissionStatus.onchange = null;
    };
  }, []);

  const start = async () => {
    setError(null);
    if (!recRef.current) {
      setError("Speech recognition is not available in this browser.");
      return false;
    }

    const micAllowed = await requestMicrophoneAccess();
    if (!micAllowed) return false;

    try {
      recRef.current.start();
      setListening(true);
      listeningRef.current = true;
      armSilence();
      return true;
    } catch {
      return listeningRef.current;
    }
  };

  const stop = () => {
    markStopped();
    try {
      recRef.current?.stop();
    } catch {
      /* ignore */
    }
    setInterim("");
  };

  const reset = () => {
    setTranscript("");
    setInterim("");
    setError(null);
  };

  return {
    supported,
    permissionState,
    listening,
    interim,
    transcript,
    error,
    start,
    stop,
    reset,
    setTranscript,
  };
}
