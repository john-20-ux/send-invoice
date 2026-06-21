import { useState } from 'react';
import { Mail, MessageSquare, Hash, Briefcase } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Switch } from '@/components/ui/switch';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';

interface BaseChannelConfig {
  enabled: boolean;
}

interface EmailChannelConfig extends BaseChannelConfig {
  subject: string;
  body: string;
}

interface WhatsAppChannelConfig extends BaseChannelConfig {
  phone: string;
  message: string;
}

interface SlackChannelConfig extends BaseChannelConfig {
  channel: string;
}

interface BasecampChannelConfig extends BaseChannelConfig {
  project: string;
}

interface NotificationConfigs {
  email: EmailChannelConfig;
  whatsapp: WhatsAppChannelConfig;
  slack: SlackChannelConfig;
  basecamp: BasecampChannelConfig;
}

type ChannelId = keyof NotificationConfigs;

const DEFAULTS: NotificationConfigs = {
  email: { enabled: true, subject: 'Your Invoice from {{company}}', body: 'Hi {{name}},\n\nPlease find your invoice attached.\n\nThank you!' },
  whatsapp: { enabled: false, phone: '', message: 'Hi {{name}}, your invoice #{{invoice_number}} is ready.' },
  slack: { enabled: false, channel: '#invoices' },
  basecamp: { enabled: false, project: '' },
};

const CHANNELS = [
  { id: 'email', label: 'Email', icon: Mail, desc: 'Send invoices and notifications via email.' },
  { id: 'whatsapp', label: 'WhatsApp', icon: MessageSquare, desc: 'Send notifications via Twilio WhatsApp.' },
  { id: 'slack', label: 'Slack', icon: Hash, desc: 'Post invoice alerts to a Slack channel.' },
  { id: 'basecamp', label: 'Basecamp', icon: Briefcase, desc: 'Post updates to a Basecamp project.' },
] as const satisfies Array<{
  id: ChannelId;
  label: string;
  icon: typeof Mail;
  desc: string;
}>;

export default function Notifications() {
  const [configs, setConfigs] = useState<NotificationConfigs>(DEFAULTS);
  const { toast } = useToast();

  const update = <TChannel extends ChannelId>(id: TChannel, patch: Partial<NotificationConfigs[TChannel]>) => {
    setConfigs(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  };

  const handleSave = (id: string) => {
    toast({ title: 'Settings Updated', description: `${id.charAt(0).toUpperCase() + id.slice(1)} notification settings saved.` });
  };

  const renderFields = (channelId: ChannelId) => {
    switch (channelId) {
      case 'email': {
        const cfg = configs.email;
        return (
          <>
            <Input placeholder="Subject" value={cfg.subject} onChange={e => update('email', { subject: e.target.value })} className="text-sm" />
            <Textarea placeholder="Message body" value={cfg.body} onChange={e => update('email', { body: e.target.value })} rows={4} className="text-sm" />
          </>
        );
      }
      case 'whatsapp': {
        const cfg = configs.whatsapp;
        return (
          <>
            <Input placeholder="+1 555 123 4567" value={cfg.phone} onChange={e => update('whatsapp', { phone: e.target.value })} className="text-sm" />
            <Textarea placeholder="Message" value={cfg.message} onChange={e => update('whatsapp', { message: e.target.value })} rows={3} className="text-sm" />
          </>
        );
      }
      case 'slack':
        return (
          <Input
            placeholder="#channel-name"
            value={configs.slack.channel}
            onChange={e => update('slack', { channel: e.target.value })}
            className="text-sm"
          />
        );
      case 'basecamp':
        return (
          <Input
            placeholder="Basecamp project name or URL"
            value={configs.basecamp.project}
            onChange={e => update('basecamp', { project: e.target.value })}
            className="text-sm"
          />
        );
    }
  };

  return (
    <div className="space-y-6 animate-fade-in-up">
      <h1 className="text-2xl font-bold text-foreground">Notifications</h1>

      <div className="grid gap-4 md:grid-cols-2">
        {CHANNELS.map(ch => {
          const cfg = configs[ch.id];
          return (
            <Card key={ch.id} className="shadow-sm">
              <CardHeader className="flex flex-row items-start gap-3 pb-3">
                <ch.icon className="h-5 w-5 text-primary mt-0.5 shrink-0" />
                <div className="flex-1">
                  <div className="flex items-center justify-between">
                    <CardTitle className="text-sm">{ch.label}</CardTitle>
                    <Switch checked={cfg.enabled} onCheckedChange={v => update(ch.id, { enabled: v })} />
                  </div>
                  <p className="text-xs text-muted-foreground mt-1">{ch.desc}</p>
                </div>
              </CardHeader>
              {cfg.enabled && (
                <CardContent className="space-y-3 pt-0">
                  {renderFields(ch.id)}
                  <Button size="sm" onClick={() => handleSave(ch.id)}>Save</Button>
                </CardContent>
              )}
            </Card>
          );
        })}
      </div>
    </div>
  );
}
