import { useEffect, useRef, useState } from "react";

/** Empty Enter while a turn runs arms a 3s "press again to steer"; the second Enter forces it. */
export function useSteerArm(busy: boolean, onSteer?: () => void) {
  const [left, setLeft] = useState(0);
  const [steering, setSteering] = useState(false);
  const steer = useRef(onSteer);
  steer.current = onSteer;

  useEffect(() => {
    if (!busy) { setLeft(0); setSteering(false); }
  }, [busy]);

  useEffect(() => {
    if (left <= 0) return;
    const id = window.setTimeout(() => setLeft(value => value - 1), 1000);
    return () => window.clearTimeout(id);
  }, [left]);

  useEffect(() => {
    if (!steering) return;
    const id = window.setTimeout(() => setSteering(false), 1400);
    return () => window.clearTimeout(id);
  }, [steering]);

  const fire = () => {
    if (!steer.current) return;
    steer.current();
    setLeft(0);
    setSteering(true);
  };

  const consumeEnter = () => {
    if (!busy || !steer.current) return false;
    if (left > 0) { fire(); return true; }
    setLeft(3);
    return true;
  };

  return { left, steering, consumeEnter, fire };
}
