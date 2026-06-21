import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Upload, CreditCard } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';

const CURRENCIES = ['USD ($)', 'EUR (€)', 'GBP (£)', 'INR (₹)'];
const FONTS = ['Inter', 'Roboto', 'Georgia', 'Courier New'];

export default function Settings() {
  const [taxRate, setTaxRate] = useState('10');
  const [currency, setCurrency] = useState('USD ($)');
  const [font, setFont] = useState('Inter');
  const { toast } = useToast();

  const handleSave = () => {
    toast({ title: 'Settings Updated', description: 'Your invoice settings have been saved.' });
  };

  return (
    <div className="space-y-6 animate-fade-in-up max-w-2xl">
      <h1 className="text-2xl font-bold text-foreground">Settings</h1>

      <Card className="shadow-sm">
        <CardHeader>
          <CardTitle className="text-base">Invoice Settings</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label className="text-sm">Tax Rate (%)</Label>
              <Input type="number" value={taxRate} onChange={e => setTaxRate(e.target.value)} min={0} max={100} step={0.5} />
            </div>
            <div className="space-y-2">
              <Label className="text-sm">Default Currency</Label>
              <Select value={currency} onValueChange={setCurrency}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {CURRENCIES.map(c => <SelectItem key={c} value={c}>{c}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label className="text-sm">Font Style</Label>
              <Select value={font} onValueChange={setFont}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {FONTS.map(f => <SelectItem key={f} value={f}>{f}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label className="text-sm">Company Logo</Label>
              <div className="flex items-center gap-2">
                <Button variant="outline" size="sm" className="gap-1">
                  <Upload className="h-3 w-3" /> Upload
                </Button>
                <span className="text-xs text-muted-foreground">PNG, JPG up to 2 MB</span>
              </div>
            </div>
          </div>
          <Button onClick={handleSave}>Save Settings</Button>
        </CardContent>
      </Card>

      <Card className="shadow-sm">
        <CardHeader>
          <CardTitle className="text-base">Notification Settings</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground mb-3">Configure Email, WhatsApp, Slack, and Basecamp notification channels.</p>
          <Button variant="outline" asChild>
            <Link to="/notifications">Manage Notifications</Link>
          </Button>
        </CardContent>
      </Card>

      <Card className="shadow-sm">
        <CardHeader className="flex flex-row items-center gap-2">
          <CreditCard className="h-5 w-5 text-primary" />
          <CardTitle className="text-base">Plan & Billing</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground mb-3">You're currently on the <strong>Free Trial</strong>. Upgrade to unlock all features.</p>
          <Button asChild>
            <Link to="/settings/plans">View Plans</Link>
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
