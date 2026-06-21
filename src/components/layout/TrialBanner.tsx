import { differenceInDays } from 'date-fns';
import { useApp } from '@/contexts/AppContext';
import { Link } from 'react-router-dom';

const TRIAL_DAYS = 14;

export function TrialBanner() {
  const { trialStartDate, currentPlan } = useApp();
  if (currentPlan !== 'trial') return null;

  const elapsed = differenceInDays(new Date(), trialStartDate);
  const remaining = Math.max(TRIAL_DAYS - elapsed, 0);

  return (
    <div className="flex items-center justify-between gap-4 bg-status-shipped-bg px-4 py-2 text-sm">
      <span className="text-status-shipped-text font-medium">
        Your free trial expires in {remaining} day{remaining !== 1 ? 's' : ''} —{' '}
        <Link to="/settings/plans" className="underline underline-offset-2 hover:opacity-80">
          Upgrade now
        </Link>
      </span>
    </div>
  );
}
