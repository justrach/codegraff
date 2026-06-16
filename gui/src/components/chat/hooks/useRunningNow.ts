import { useEffect, useState } from "react";

export function useRunningNow(isRunning: boolean) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!isRunning) {
      return;
    }

    const interval = window.setInterval(() => {
      setNow(Date.now());
    }, 1000);

    return () => {
      window.clearInterval(interval);
    };
  }, [isRunning]);

  return now;
}
