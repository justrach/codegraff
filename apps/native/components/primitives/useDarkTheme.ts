"use client";
import { useSyncExternalStore } from 'react';
import { themeStore } from '@/lib/theme-store';
const serverSnapshot = () => false;
export const useDarkTheme = () => useSyncExternalStore(themeStore.subscribe, themeStore.getSnapshot, serverSnapshot);
