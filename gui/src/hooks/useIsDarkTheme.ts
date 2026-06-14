import { useEffect, useState } from "react";

function readIsDarkTheme() {
  return document.documentElement.classList.contains("dark");
}

export function useIsDarkTheme() {
  const [isDarkTheme, setIsDarkTheme] = useState(readIsDarkTheme);

  useEffect(() => {
    const root = document.documentElement;
    const observer = new MutationObserver(() => {
      setIsDarkTheme(root.classList.contains("dark"));
    });

    observer.observe(root, {
      attributeFilter: ["class"],
      attributes: true,
    });

    return () => {
      observer.disconnect();
    };
  }, []);

  return isDarkTheme;
}
