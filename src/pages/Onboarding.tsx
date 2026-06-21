import { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowRight, Check, Store, Loader2, AlertCircle, Mail } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Progress } from '@/components/ui/progress';
import { useApp } from '@/contexts/AppContext';
import { useToast } from '@/hooks/use-toast';
import { api } from '@/services/api';
import type { SyncStatus } from '@/types/shopify';

const STEPS = ['Email', 'Connect', 'Setup'];

export default function Onboarding() {
  const {
    onboardingStep, setOnboardingStep, setOnboarded,
    setEmail: saveEmail, shopDomain, setShopName,
  } = useApp();
  const navigate = useNavigate();
  const { toast } = useToast();

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-4">
      <div className="max-w-lg w-full">
        {/* Step indicator */}
        <div className="flex items-center justify-center gap-2 mb-8">
          {STEPS.map((label, i) => {
            const stepNum = i + 1;
            return (
              <div key={label} className="flex items-center gap-2">
                <div className={`flex items-center justify-center h-8 w-8 rounded-full text-xs font-semibold transition-colors ${
                  stepNum < onboardingStep ? 'bg-accent text-accent-foreground' :
                  stepNum === onboardingStep ? 'bg-primary text-primary-foreground' :
                  'bg-muted text-muted-foreground'
                }`}>
                  {stepNum < onboardingStep ? <Check className="h-4 w-4" /> : stepNum}
                </div>
                {i < STEPS.length - 1 && (
                  <div className={`h-0.5 w-8 rounded ${stepNum < onboardingStep ? 'bg-accent' : 'bg-border'}`} />
                )}
              </div>
            );
          })}
        </div>

        <div className="bg-card rounded-lg shadow-lg p-8 animate-fade-in-up">
          {onboardingStep === 1 && (
            <Step1Email
              onContinue={(email) => {
                if (email) saveEmail(email);
                api.saveEmail(email);
                setOnboardingStep(2);
              }}
              onSkip={() => {
                api.saveEmail(null);
                setOnboardingStep(2);
              }}
            />
          )}
          {onboardingStep === 2 && (
            <Step2Connect
              shopDomain={shopDomain}
              onConnected={(name) => {
                setShopName(name);
                setOnboardingStep(3);
              }}
            />
          )}
          {onboardingStep === 3 && (
            <Step3Setup
              onComplete={() => {
                setOnboarded(true);
                toast({ title: 'Store synced!', description: 'Your Shopify data is ready.' });
                navigate('/dashboard');
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}

// Step 1: Email Collection
function Step1Email({ onContinue, onSkip }: { onContinue: (email: string | null) => void; onSkip: () => void }) {
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');

  const handleSubmit = () => {
    if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      setError('Please enter a valid email address.');
      return;
    }
    setError('');
    onContinue(email || null);
  };

  return (
    <>
      <div className="flex items-center gap-3 mb-4">
        <div className="h-10 w-10 rounded-full bg-primary/10 flex items-center justify-center">
          <Mail className="h-5 w-5 text-primary" />
        </div>
        <div>
          <h1 className="text-xl font-bold text-card-foreground">Welcome!</h1>
          <p className="text-sm text-muted-foreground">Enter your email to receive updates (optional).</p>
        </div>
      </div>
      <div className="space-y-4 mt-6">
        <div>
          <Input
            type="email"
            placeholder="you@example.com"
            value={email}
            onChange={e => { setEmail(e.target.value); setError(''); }}
          />
          {error && <p className="text-sm text-destructive mt-1">{error}</p>}
        </div>
        <Button className="w-full" onClick={handleSubmit}>
          Continue <ArrowRight className="h-4 w-4 ml-1" />
        </Button>
        <button
          onClick={onSkip}
          className="w-full text-center text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Skip for now
        </button>
      </div>
    </>
  );
}

// Step 2: Connect Shopify Store
function Step2Connect({ shopDomain, onConnected }: { shopDomain: string; onConnected: (shopName: string) => void }) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleConnect = async () => {
    setLoading(true);
    setError('');
    try {
      const result = await api.connectStore(shopDomain);
      onConnected(result.shopName);
    } catch (err) {
      setError(err instanceof Error ? err.message : "We couldn't connect to this store. Please reinstall.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="text-center">
      <Store className="h-12 w-12 text-primary mx-auto mb-4" />
      <h2 className="text-xl font-semibold mb-2 text-card-foreground">Connect Your Shopify Store</h2>
      <p className="text-sm text-muted-foreground mb-6">Confirm your Shopify store domain.</p>
      <div className="mb-6">
        <Input
          value={shopDomain}
          readOnly
          className="text-center bg-muted/50"
        />
      </div>
      {error && (
        <div className="flex items-center gap-2 text-destructive text-sm mb-4 justify-center">
          <AlertCircle className="h-4 w-4" />
          <span>{error}</span>
        </div>
      )}
      <Button className="w-full" onClick={handleConnect} disabled={loading}>
        {loading ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : <Store className="h-4 w-4 mr-2" />}
        Connect Store
      </Button>
    </div>
  );
}

// Step 3: Loading / Initialising
function Step3Setup({ onComplete }: { onComplete: () => void }) {
  const [syncStatus, setSyncStatus] = useState<SyncStatus | null>(null);
  const [error, setError] = useState(false);
  const [started, setStarted] = useState(false);

  const startSync = useCallback(async () => {
    setError(false);
    setStarted(true);
    const result = await api.triggerSync('full');
    if (!result.started) {
      // Reset rate limit and retry for initial sync
      api.resetSyncRateLimit();
      await api.triggerSync('full');
    }
  }, []);

  useEffect(() => {
    if (!started) {
      startSync();
    }
  }, [started, startSync]);

  // Poll every 2 seconds
  useEffect(() => {
    if (!started) return;
    const poll = setInterval(async () => {
      const status = await api.getSyncStatus();
      setSyncStatus(status);
      if (status.status === 'completed') {
        clearInterval(poll);
        setTimeout(onComplete, 500);
      } else if (status.status === 'failed') {
        clearInterval(poll);
        setError(true);
      }
    }, 2000);
    return () => clearInterval(poll);
  }, [started, onComplete]);

  const pct = syncStatus
    ? Math.round((syncStatus.ordersSynced / Math.max(syncStatus.totalEstimated, 1)) * 100)
    : 0;

  if (error) {
    return (
      <div className="text-center">
        <AlertCircle className="h-12 w-12 text-destructive mx-auto mb-4" />
        <h2 className="text-xl font-semibold mb-2 text-card-foreground">Sync Failed</h2>
        <p className="text-sm text-muted-foreground mb-6">Something went wrong while syncing your store data.</p>
        <Button className="w-full" onClick={() => { setStarted(false); }}>
          Retry
        </Button>
      </div>
    );
  }

  return (
    <div className="text-center">
      <Loader2 className="h-12 w-12 text-primary mx-auto mb-4 animate-spin" />
      <h2 className="text-xl font-semibold mb-2 text-card-foreground">Setting up your store…</h2>
      <p className="text-sm text-muted-foreground mb-6">This only takes a moment.</p>
      {syncStatus && syncStatus.status === 'running' && (
        <div className="space-y-2">
          <Progress value={pct} className="h-2" />
          <p className="text-xs text-muted-foreground">
            Syncing orders… {syncStatus.ordersSynced} of {syncStatus.totalEstimated}
          </p>
        </div>
      )}
    </div>
  );
}
