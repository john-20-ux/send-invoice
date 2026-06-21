import { useState } from 'react';
import { HelpCircle, MessageCircle, Book, Mail } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Button } from '@/components/ui/button';
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion';
import { useToast } from '@/hooks/use-toast';

const FAQ = [
  { q: 'How do I connect my Shopify store?', a: 'Go through the onboarding flow or visit Settings to reconnect. We use Shopify OAuth for secure access.' },
  { q: 'Can I customize invoice templates?', a: 'Yes! Visit Invoice Templates to choose a design and customize every field, including line items, taxes, and branding.' },
  { q: 'Which notification channels are supported?', a: 'We support Email, WhatsApp (via Twilio), Slack, and Basecamp. Toggle each in the Notifications page.' },
  { q: 'How is commission calculated for vendors?', a: "Commission is a configurable percentage of each vendor's total revenue. You can edit rates inline on the Vendors page." },
  { q: 'What happens when my trial expires?', a: "You'll need to select a paid plan to continue using all features. Visit Settings > Plans to upgrade." },
];

export default function Support() {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [message, setMessage] = useState('');
  const { toast } = useToast();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    toast({ title: 'Message Sent', description: "We'll get back to you within 24 hours." });
    setName(''); setEmail(''); setMessage('');
  };

  return (
    <div className="space-y-6 animate-fade-in-up max-w-3xl">
      <h1 className="text-2xl font-bold text-foreground">Support</h1>

      <div className="grid gap-4 sm:grid-cols-3">
        {[
          { icon: Book, title: 'Documentation', desc: 'Guides & tutorials' },
          { icon: MessageCircle, title: 'Live Chat', desc: 'Chat with our team' },
          { icon: Mail, title: 'Email Support', desc: 'support@lovable.app' },
        ].map(item => (
          <Card key={item.title} className="shadow-sm text-center cursor-pointer hover:shadow-md transition-shadow">
            <CardContent className="pt-6">
              <item.icon className="h-8 w-8 text-primary mx-auto mb-2" />
              <p className="text-sm font-medium">{item.title}</p>
              <p className="text-xs text-muted-foreground">{item.desc}</p>
            </CardContent>
          </Card>
        ))}
      </div>

      <Card className="shadow-sm">
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <HelpCircle className="h-5 w-5 text-primary" /> Frequently Asked Questions
          </CardTitle>
        </CardHeader>
        <CardContent>
          <Accordion type="single" collapsible className="w-full">
            {FAQ.map((item, i) => (
              <AccordionItem key={i} value={`item-${i}`}>
                <AccordionTrigger className="text-sm text-left">{item.q}</AccordionTrigger>
                <AccordionContent className="text-sm text-muted-foreground">{item.a}</AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </CardContent>
      </Card>

      <Card className="shadow-sm">
        <CardHeader>
          <CardTitle className="text-base">Contact Us</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <Input placeholder="Your name" value={name} onChange={e => setName(e.target.value)} required />
              <Input type="email" placeholder="Your email" value={email} onChange={e => setEmail(e.target.value)} required />
            </div>
            <Textarea placeholder="How can we help?" value={message} onChange={e => setMessage(e.target.value)} rows={4} required />
            <Button type="submit">Send Message</Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
