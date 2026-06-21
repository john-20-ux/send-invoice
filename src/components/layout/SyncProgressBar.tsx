import { RefreshCw, AlertTriangle, CheckCircle2 } from 'lucide-react';
import { Progress } from '@/components/ui/progress';
import { useApp } from '@/contexts/AppContext';
import { formatDistanceToNow } from 'date-fns';

export function SyncProgressBar() {
  const { syncStatus } = useApp();

  if (syncStatus.status === 'running') {
    const pct = syncStatus.totalEstimated > 0
      ? Math.round((syncStatus.ordersSynced / syncStatus.totalEstimated) * 100)
      : 0;
    return (
      <div className="flex items-center gap-3 px-4 py-1.5 bg-primary/5 border-b border-border text-sm">
        <RefreshCw className="h-3.5 w-3.5 text-primary animate-spin shrink-0" />
        <span className="text-xs text-muted-foreground whitespace-nowrap">
          Syncing orders… {syncStatus.ordersSynced} synced
        </span>
        <Progress value={pct} className="h-1.5 flex-1 max-w-[200px]" />
        <span className="text-xs text-muted-foreground">{pct}%</span>
      </div>
    );
  }

  if (syncStatus.status === 'failed') {
    return (
      <div className="flex items-center gap-2 px-4 py-1.5 bg-destructive/5 border-b border-border text-sm">
        <AlertTriangle className="h-3.5 w-3.5 text-destructive shrink-0" />
        <span className="text-xs text-destructive">Sync failed</span>
      </div>
    );
  }

  if (syncStatus.lastSyncedAt) {
    return (
      <div className="flex items-center gap-2 px-4 py-1.5 bg-card border-b border-border text-sm">
        <CheckCircle2 className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
        <span className="text-xs text-muted-foreground">
          Last synced: {formatDistanceToNow(new Date(syncStatus.lastSyncedAt), { addSuffix: true })}
        </span>
      </div>
    );
  }

  return null;
}
