import React from 'react';
import { Navigate } from 'react-router-dom';
import { SidebarProvider, SidebarTrigger } from '@/components/ui/sidebar';
import { AppSidebar } from './AppSidebar';
import { TrialBanner } from './TrialBanner';
import { SyncProgressBar } from './SyncProgressBar';
import { useApp } from '@/contexts/AppContext';

export function AppLayout({ children }: { children: React.ReactNode }) {
  const { onboarded } = useApp();

  if (!onboarded) return <Navigate to="/onboarding" replace />;

  return (
    <SidebarProvider>
      <div className="min-h-screen flex w-full">
        <AppSidebar />
        <div className="flex-1 flex flex-col min-w-0">
          <TrialBanner />
          <SyncProgressBar />
          <header className="h-12 flex items-center border-b border-border px-4 bg-card shrink-0">
            <SidebarTrigger className="mr-2" />
          </header>
          <main className="flex-1 p-6 overflow-auto">
            {children}
          </main>
        </div>
      </div>
    </SidebarProvider>
  );
}
