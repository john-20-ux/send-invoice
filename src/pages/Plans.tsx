import { Check } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { useApp } from '@/contexts/AppContext';
import { useToast } from '@/hooks/use-toast';

type PlanId = 'basic' | 'growth' | 'pro' | 'enterprise';

interface PlanDefinition {
  id: PlanId;
  name: string;
  price: string;
  period: string;
  tagline: string;
  features: string[];
  popular?: boolean;
}

const PLANS: PlanDefinition[] = [
  {
    id: 'basic', name: 'Basic', price: '$9', period: '/mo', tagline: 'For Shopify Basic stores',
    features: ['Basic invoice templates', 'Email & SMS notifications', 'Up to 100 orders/month'],
  },
  {
    id: 'growth', name: 'Growth', price: '$29', period: '/mo', tagline: 'For growing stores', popular: true,
    features: ['All Basic features', 'Customizable invoice templates', 'Advanced notifications (abandoned cart, delays)', 'Analytics & invoice tracking'],
  },
  {
    id: 'pro', name: 'Pro', price: '$79', period: '/mo', tagline: 'For Shopify Advanced stores',
    features: ['All Growth features', 'Multi-language & multi-currency invoices', 'Detailed invoice & notification reports', 'Priority support'],
  },
  {
    id: 'enterprise', name: 'Enterprise', price: 'Custom', period: '', tagline: 'For Shopify Plus',
    features: ['All Pro features', 'Dedicated account manager', 'Custom ERP/CRM integrations', 'Subscription invoices, tiered pricing'],
  },
];

export default function Plans() {
  const { currentPlan, setCurrentPlan } = useApp();
  const { toast } = useToast();

  const handleUpgrade = (planId: PlanId) => {
    if (planId === 'enterprise') {
      toast({ title: 'Contact Sales', description: "We'll reach out to discuss your needs." });
      return;
    }
    setCurrentPlan(planId);
    toast({ title: 'Plan Updated', description: `You're now on the ${planId.charAt(0).toUpperCase() + planId.slice(1)} plan.` });
  };

  return (
    <div className="space-y-6 animate-fade-in-up">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Plans & Billing</h1>
        <p className="text-sm text-muted-foreground mt-1">Choose the right plan for your store.</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {PLANS.map(plan => {
          const isActive = currentPlan === plan.id;
          return (
            <Card key={plan.id} className={`shadow-sm relative flex flex-col ${plan.popular ? 'border-primary border-2' : ''}`}>
              {plan.popular && (
                <div className="absolute -top-3 left-1/2 -translate-x-1/2">
                  <Badge className="text-[10px]">Most Popular</Badge>
                </div>
              )}
              <CardHeader className="pb-3">
                <CardTitle className="text-base">{plan.name}</CardTitle>
                <p className="text-xs text-muted-foreground">{plan.tagline}</p>
                <div className="mt-2">
                  <span className="text-3xl font-bold tabular-nums text-card-foreground">{plan.price}</span>
                  <span className="text-sm text-muted-foreground">{plan.period}</span>
                </div>
              </CardHeader>
              <CardContent className="flex-1 flex flex-col">
                <ul className="space-y-2 flex-1 mb-4">
                  {plan.features.map(f => (
                    <li key={f} className="flex items-start gap-2 text-xs text-card-foreground">
                      <Check className="h-3.5 w-3.5 text-accent shrink-0 mt-0.5" />
                      {f}
                    </li>
                  ))}
                </ul>
                {isActive ? (
                  <Badge variant="success" className="w-full justify-center py-1.5">Active</Badge>
                ) : (
                  <Button
                    variant={plan.id === 'enterprise' ? 'outline' : 'default'}
                    className="w-full"
                    onClick={() => handleUpgrade(plan.id)}
                  >
                    {plan.id === 'enterprise' ? 'Contact Sales' : 'Upgrade'}
                  </Button>
                )}
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
