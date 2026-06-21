import { Loader2 } from 'lucide-react';
import { useApp } from '@/contexts/AppContext';
import { Progress } from '@/components/ui/progress';

export function SyncOverlay() {
  const { syncStatus } = useApp();
  if (syncStatus.status !== 'running') return null;

  const pct = syncStatus.totalEstimated > 0
    ? Math.round((syncStatus.ordersSynced / syncStatus.totalEstimated) * 100)
    : 0;
  const progressText = syncStatus.totalEstimated > 0
    ? `Synced ${syncStatus.ordersSynced} of ${syncStatus.totalEstimated} orders`
    : `Synced ${syncStatus.ordersSynced} orders`;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-foreground/60 backdrop-blur-sm animate-fade-in">
      <div className="bg-card rounded-lg p-8 shadow-2xl text-center max-w-md w-full mx-4 animate-fade-in-up">
        <Loader2 className="h-10 w-10 text-primary mx-auto mb-4 animate-spin-slow" />
        <h2 className="text-xl font-semibold mb-2 text-card-foreground">Syncing your store</h2>
        <p className="text-muted-foreground text-sm mb-4">{progressText}</p>
        <Progress value={pct} className="h-2" />
        <p className="text-xs text-muted-foreground mt-2">{pct}%</p>
      </div>
    </div>
  );
}
