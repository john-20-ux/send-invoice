import React, { createContext, useContext, useState, useCallback, useEffect, useRef } from 'react';
import type { SyncStatus } from '@/types/shopify';
import { api } from '@/services/api';

interface AppContextType {
  onboarded: boolean;
  onboardingStep: number;
  syncing: boolean;
  syncStatus: SyncStatus;
  trialStartDate: Date;
  currentPlan: 'trial' | 'basic' | 'growth' | 'pro' | 'enterprise';
  email: string;
  shopDomain: string;
  shopName: string;
  setOnboarded: (v: boolean) => void;
  setOnboardingStep: (step: number) => void;
  setEmail: (e: string) => void;
  setShopDomain: (d: string) => void;
  setShopName: (n: string) => void;
  triggerSync: (type?: 'full' | 'incremental') => Promise<{ started: boolean; message?: string }>;
  refreshSyncStatus: () => Promise<void>;
  setCurrentPlan: (p: AppContextType['currentPlan']) => void;
}

const defaultSyncStatus: SyncStatus = {
  status: 'idle',
  ordersSynced: 0,
  totalEstimated: 0,
  startedAt: null,
  finishedAt: null,
  lastSyncedAt: null,
};

const AppContext = createContext<AppContextType | null>(null);

export function AppProvider({ children }: { children: React.ReactNode }) {
  const [onboarded, setOnboardedState] = useState(() => localStorage.getItem('shopify_onboarded') === 'true');
  const [onboardingStep, setOnboardingStep] = useState(1);
  const [syncStatus, setSyncStatus] = useState<SyncStatus>(defaultSyncStatus);
  const [currentPlan, setCurrentPlan] = useState<AppContextType['currentPlan']>('trial');
  const [email, setEmail] = useState('');
  const [shopDomain, setShopDomain] = useState(() => api.getShopDomain());
  const [shopName, setShopName] = useState(() => api.getShopName());
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const syncing = syncStatus.status === 'running';

  const trialStartDate = new Date();
  trialStartDate.setDate(trialStartDate.getDate() - 7);

  const setOnboarded = useCallback((v: boolean) => {
    setOnboardedState(v);
    localStorage.setItem('shopify_onboarded', String(v));
  }, []);

  const refreshSyncStatus = useCallback(async () => {
    const status = await api.getSyncStatus();
    setSyncStatus(status);
  }, []);

  const triggerSync = useCallback(async (type: 'full' | 'incremental' = 'incremental') => {
    const result = await api.triggerSync(type);
    if (result.started) {
      await refreshSyncStatus();
    }
    return result;
  }, [refreshSyncStatus]);

  // Poll sync status when syncing
  useEffect(() => {
    if (syncing) {
      pollRef.current = setInterval(async () => {
        const status = await api.getSyncStatus();
        setSyncStatus(status);
        if (status.status !== 'running' && pollRef.current) {
          clearInterval(pollRef.current);
          pollRef.current = null;
        }
      }, 2000);
    }
    return () => {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, [syncing]);

  // Background poll for status when onboarded (every 10s)
  useEffect(() => {
    if (!onboarded) return;
    const interval = setInterval(refreshSyncStatus, 10000);
    return () => clearInterval(interval);
  }, [onboarded, refreshSyncStatus]);

  return (
    <AppContext.Provider value={{
      onboarded, onboardingStep, syncing, syncStatus, trialStartDate, currentPlan, email,
      shopDomain, shopName,
      setOnboarded, setOnboardingStep, setEmail, setShopDomain, setShopName,
      triggerSync, refreshSyncStatus, setCurrentPlan,
    }}>
      {children}
    </AppContext.Provider>
  );
}

export function useApp() {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp must be inside AppProvider');
  return ctx;
}
