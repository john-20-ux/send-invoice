import { useState, useCallback } from 'react';
import { Check, Eye, EyeOff, GripVertical, RotateCcw, Printer, Download } from 'lucide-react';
import { generatePdfFromElement } from '@/lib/pdfUtils';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Switch } from '@/components/ui/switch';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useToast } from '@/hooks/use-toast';

const TEMPLATES = [
  { id: 'classic', name: 'Classic', color: 'bg-muted' },
  { id: 'modern', name: 'Modern', color: 'bg-primary/10' },
  { id: 'minimal', name: 'Minimal', color: 'bg-card' },
  { id: 'bold', name: 'Bold', color: 'bg-foreground/5' },
  { id: 'clean', name: 'Clean', color: 'bg-accent/10' },
  { id: 'compact', name: 'Compact', color: 'bg-secondary' },
];

interface FieldConfig {
  key: string;
  label: string;
  group: string;
  visible: boolean;
  value: string;
}

const DEFAULT_FIELDS: FieldConfig[] = [
  { key: 'company_name', label: 'Company Name', group: 'Header', visible: true, value: 'Acme Store' },
  { key: 'tagline', label: 'Tagline', group: 'Header', visible: true, value: 'Quality products delivered' },
  { key: 'address', label: 'Address', group: 'Header', visible: true, value: '123 Commerce St, Suite 4' },
  { key: 'phone', label: 'Phone', group: 'Header', visible: true, value: '+1 (555) 123-4567' },
  { key: 'email', label: 'Email', group: 'Header', visible: true, value: 'billing@acmestore.com' },
  { key: 'website', label: 'Website', group: 'Header', visible: false, value: 'www.acmestore.com' },
  { key: 'gst', label: 'GST/VAT Number', group: 'Header', visible: true, value: 'GST1234567890' },
  { key: 'bill_to', label: 'Bill To', group: 'Client', visible: true, value: 'Sarah Mitchell' },
  { key: 'client_address', label: 'Client Address', group: 'Client', visible: true, value: '456 Oak Ave' },
  { key: 'client_email', label: 'Client Email', group: 'Client', visible: true, value: 'sarah@email.com' },
  { key: 'invoice_number', label: 'Invoice Number', group: 'Invoice Meta', visible: true, value: 'INV-1001' },
  { key: 'invoice_date', label: 'Invoice Date', group: 'Invoice Meta', visible: true, value: 'Mar 21, 2026' },
  { key: 'due_date', label: 'Due Date', group: 'Invoice Meta', visible: true, value: 'Apr 20, 2026' },
  { key: 'payment_terms', label: 'Payment Terms', group: 'Invoice Meta', visible: true, value: 'Net 30' },
  { key: 'notes', label: 'Notes', group: 'Footer', visible: true, value: 'Thank you for your business!' },
  { key: 'bank_details', label: 'Bank Details', group: 'Footer', visible: true, value: 'Bank of Commerce, Acct: 12345678' },
  { key: 'terms', label: 'Terms & Conditions', group: 'Footer', visible: false, value: 'Payment due within 30 days.' },
];

interface LineItem {
  desc: string;
  qty: number;
  rate: number;
  discount: number;
  tax: number;
}

const DEFAULT_ITEMS: LineItem[] = [
  { desc: 'Wireless Earbuds Pro', qty: 2, rate: 89.99, discount: 0, tax: 10 },
  { desc: 'Premium Dog Harness', qty: 1, rate: 45.00, discount: 5, tax: 10 },
];

const CURRENCIES = [
  { symbol: '$', label: 'USD' },
  { symbol: '€', label: 'EUR' },
  { symbol: '£', label: 'GBP' },
  { symbol: '₹', label: 'INR' },
];

export default function InvoiceTemplates() {
  const [selectedTemplate, setSelectedTemplate] = useState('classic');
  const [fields, setFields] = useState<FieldConfig[]>(() => {
    const saved = localStorage.getItem('lovable_invoice_fields');
    return saved ? JSON.parse(saved) : DEFAULT_FIELDS;
  });
  const [lineItems, setLineItems] = useState<LineItem[]>(() => {
    const saved = localStorage.getItem('lovable_invoice_items');
    return saved ? JSON.parse(saved) : DEFAULT_ITEMS;
  });
  const [currency, setCurrency] = useState('$');
  const { toast } = useToast();

  const save = useCallback((f: FieldConfig[], items: LineItem[]) => {
    localStorage.setItem('lovable_invoice_fields', JSON.stringify(f));
    localStorage.setItem('lovable_invoice_items', JSON.stringify(items));
  }, []);

  const toggleField = (key: string) => {
    const next = fields.map(f => f.key === key ? { ...f, visible: !f.visible } : f);
    setFields(next);
    save(next, lineItems);
  };

  const updateFieldValue = (key: string, value: string) => {
    const next = fields.map(f => f.key === key ? { ...f, value } : f);
    setFields(next);
    save(next, lineItems);
  };

  const updateItem = (idx: number, patch: Partial<LineItem>) => {
    const next = lineItems.map((it, i) => i === idx ? { ...it, ...patch } : it);
    setLineItems(next);
    save(fields, next);
  };

  const addItem = () => {
    const next = [...lineItems, { desc: 'New Item', qty: 1, rate: 0, discount: 0, tax: 0 }];
    setLineItems(next);
    save(fields, next);
  };

  const removeItem = (idx: number) => {
    const next = lineItems.filter((_, i) => i !== idx);
    setLineItems(next);
    save(fields, next);
  };

  const reset = () => {
    setFields(DEFAULT_FIELDS);
    setLineItems(DEFAULT_ITEMS);
    save(DEFAULT_FIELDS, DEFAULT_ITEMS);
    toast({ title: 'Reset', description: 'Invoice template reset to defaults.' });
  };

  const [downloading, setDownloading] = useState(false);

  const handleDownloadPdf = async () => {
    const el = document.getElementById('invoice-preview');
    if (!el) return;
    setDownloading(true);
    try {
      await generatePdfFromElement(el, { filename: 'invoice.pdf' });
      toast({ title: 'PDF Downloaded', description: 'Your invoice has been saved as a PDF.' });
    } catch {
      toast({ title: 'Error', description: 'Failed to generate PDF.', variant: 'destructive' });
    } finally {
      setDownloading(false);
    }
  };

  const handlePrint = () => {
    const el = document.getElementById('invoice-preview');
    if (!el) return;
    const win = window.open('', '_blank');
    if (!win) return;
    win.document.write(`<html><head><title>Invoice</title><style>body{margin:0;font-family:Inter,system-ui,sans-serif}@page{size:A4;margin:0}</style></head><body>${el.innerHTML}</body></html>`);
    win.document.close();
    win.print();
  };

  const visible = fields.filter(f => f.visible);
  const groups = [...new Set(fields.map(f => f.group))];

  const subtotal = lineItems.reduce((s, it) => {
    const base = it.qty * it.rate;
    return s + base - base * it.discount / 100;
  }, 0);
  const totalTax = lineItems.reduce((s, it) => {
    const base = it.qty * it.rate;
    const afterDisc = base - base * it.discount / 100;
    return s + afterDisc * it.tax / 100;
  }, 0);
  const grandTotal = subtotal + totalTax;

  return (
    <div className="space-y-6 animate-fade-in-up">
      <h1 className="text-2xl font-bold text-foreground">Invoice Templates</h1>

      {/* Template selector */}
      <div className="grid grid-cols-3 sm:grid-cols-6 gap-3">
        {TEMPLATES.map(t => (
          <button
            key={t.id}
            onClick={() => { setSelectedTemplate(t.id); toast({ title: 'Template Selected', description: `${t.name} template active.` }); }}
            className={`relative rounded-lg border-2 p-3 text-center transition-all hover:shadow-md active:scale-[0.97] ${
              selectedTemplate === t.id ? 'border-primary shadow-md' : 'border-border'
            }`}
          >
            <div className={`${t.color} rounded h-16 mb-2 flex items-center justify-center`}>
              <div className="w-8 h-10 bg-card/80 rounded-sm shadow-sm" />
            </div>
            <span className="text-xs font-medium">{t.name}</span>
            {selectedTemplate === t.id && (
              <div className="absolute top-1.5 right-1.5 h-5 w-5 rounded-full bg-primary flex items-center justify-center">
                <Check className="h-3 w-3 text-primary-foreground" />
              </div>
            )}
          </button>
        ))}
      </div>

      {/* Two-panel editor */}
      <div className="grid lg:grid-cols-[340px_1fr] gap-6">
        {/* Left: Field Customizer */}
        <div className="space-y-4 max-h-[70vh] overflow-y-auto scrollbar-thin pr-2">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-foreground">Fields</h3>
            <Select value={currency} onValueChange={setCurrency}>
              <SelectTrigger className="w-20 h-8 text-xs">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {CURRENCIES.map(c => <SelectItem key={c.symbol} value={c.symbol}>{c.symbol} {c.label}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          {groups.map(g => (
            <div key={g} className="space-y-1">
              <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">{g}</p>
              {fields.filter(f => f.group === g).map(f => (
                <div key={f.key} className="flex items-center gap-2 py-1">
                  <GripVertical className="h-3 w-3 text-muted-foreground/40 shrink-0 cursor-grab" />
                  <Switch checked={f.visible} onCheckedChange={() => toggleField(f.key)} className="shrink-0 scale-75" />
                  <span className="text-xs text-muted-foreground min-w-[80px]">{f.label}</span>
                  {f.visible ? <Eye className="h-3 w-3 text-accent shrink-0" /> : <EyeOff className="h-3 w-3 text-muted-foreground/40 shrink-0" />}
                </div>
              ))}
            </div>
          ))}

          <Button variant="outline" size="sm" className="w-full gap-1 text-xs" onClick={reset}>
            <RotateCcw className="h-3 w-3" /> Reset to default
          </Button>
        </div>

        {/* Right: A4 Preview */}
        <div className="space-y-3">
          <div className="flex items-center gap-2">
            <Button variant="default" size="sm" className="gap-1" onClick={handleDownloadPdf} disabled={downloading}>
              <Download className="h-4 w-4" /> {downloading ? 'Generating…' : 'Download PDF'}
            </Button>
            <Button variant="outline" size="sm" className="gap-1" onClick={handlePrint}>
              <Printer className="h-4 w-4" /> Print
            </Button>
          </div>

          <div
            id="invoice-preview"
            className="bg-card border rounded-lg shadow-sm mx-auto overflow-hidden"
            style={{ width: 794, minHeight: 1123, padding: 48, fontFamily: 'Inter, system-ui, sans-serif', fontSize: 13 }}
          >
            {/* Header */}
            {visible.filter(f => f.group === 'Header').length > 0 && (
              <div className="mb-6 border-b pb-4" style={{ borderColor: '#e5e7eb' }}>
                {visible.find(f => f.key === 'company_name') && (
                  <h2
                    contentEditable
                    suppressContentEditableWarning
                    onBlur={e => updateFieldValue('company_name', e.currentTarget.textContent || '')}
                    className="text-xl font-bold outline-none focus:ring-1 focus:ring-primary/30 rounded px-1"
                    style={{ color: '#1a1a2e' }}
                  >
                    {visible.find(f => f.key === 'company_name')?.value}
                  </h2>
                )}
                {visible.find(f => f.key === 'tagline') && (
                  <p contentEditable suppressContentEditableWarning onBlur={e => updateFieldValue('tagline', e.currentTarget.textContent || '')} className="text-xs outline-none" style={{ color: '#6b7280' }}>
                    {visible.find(f => f.key === 'tagline')?.value}
                  </p>
                )}
                <div className="flex flex-wrap gap-x-4 gap-y-0.5 mt-2 text-xs" style={{ color: '#6b7280' }}>
                  {['address', 'phone', 'email', 'website', 'gst'].map(k => {
                    const f = visible.find(f => f.key === k);
                    return f ? (
                      <span key={k} contentEditable suppressContentEditableWarning onBlur={e => updateFieldValue(k, e.currentTarget.textContent || '')} className="outline-none">
                        {f.value}
                      </span>
                    ) : null;
                  })}
                </div>
              </div>
            )}

            {/* Client + Invoice Meta */}
            <div className="flex justify-between mb-6 gap-8">
              {visible.filter(f => f.group === 'Client').length > 0 && (
                <div>
                  <p className="text-xs font-semibold mb-1" style={{ color: '#6b7280' }}>BILL TO</p>
                  {visible.filter(f => f.group === 'Client').map(f => (
                    <p key={f.key} contentEditable suppressContentEditableWarning onBlur={e => updateFieldValue(f.key, e.currentTarget.textContent || '')} className="text-xs outline-none" style={{ color: '#374151' }}>
                      {f.value}
                    </p>
                  ))}
                </div>
              )}
              {visible.filter(f => f.group === 'Invoice Meta').length > 0 && (
                <div className="text-right">
                  {visible.filter(f => f.group === 'Invoice Meta').map(f => (
                    <p key={f.key} className="text-xs" style={{ color: '#374151' }}>
                      <span style={{ color: '#6b7280' }}>{f.label}: </span>
                      <span contentEditable suppressContentEditableWarning onBlur={e => updateFieldValue(f.key, e.currentTarget.textContent || '')} className="outline-none font-medium">
                        {f.value}
                      </span>
                    </p>
                  ))}
                </div>
              )}
            </div>

            {/* Line Items Table */}
            <table className="w-full text-xs mb-4" style={{ borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ backgroundColor: '#f3f4f6' }}>
                  <th className="text-left py-2 px-2 font-semibold" style={{ color: '#374151' }}>Description</th>
                  <th className="text-right py-2 px-2 font-semibold" style={{ color: '#374151' }}>Qty</th>
                  <th className="text-right py-2 px-2 font-semibold" style={{ color: '#374151' }}>Rate</th>
                  <th className="text-right py-2 px-2 font-semibold" style={{ color: '#374151' }}>Disc%</th>
                  <th className="text-right py-2 px-2 font-semibold" style={{ color: '#374151' }}>Tax%</th>
                  <th className="text-right py-2 px-2 font-semibold" style={{ color: '#374151' }}>Amount</th>
                  <th className="w-6"></th>
                </tr>
              </thead>
              <tbody>
                {lineItems.map((it, i) => {
                  const base = it.qty * it.rate;
                  const afterDisc = base - base * it.discount / 100;
                  const amount = afterDisc + afterDisc * it.tax / 100;
                  return (
                    <tr key={i} style={{ borderBottom: '1px solid #e5e7eb' }}>
                      <td className="py-1.5 px-2">
                        <input className="w-full outline-none bg-transparent text-xs" value={it.desc} onChange={e => updateItem(i, { desc: e.target.value })} />
                      </td>
                      <td className="py-1.5 px-2 text-right"><input type="number" className="w-12 text-right outline-none bg-transparent text-xs tabular-nums" value={it.qty} onChange={e => updateItem(i, { qty: +e.target.value })} /></td>
                      <td className="py-1.5 px-2 text-right"><input type="number" className="w-16 text-right outline-none bg-transparent text-xs tabular-nums" value={it.rate} onChange={e => updateItem(i, { rate: +e.target.value })} step={0.01} /></td>
                      <td className="py-1.5 px-2 text-right"><input type="number" className="w-12 text-right outline-none bg-transparent text-xs tabular-nums" value={it.discount} onChange={e => updateItem(i, { discount: +e.target.value })} /></td>
                      <td className="py-1.5 px-2 text-right"><input type="number" className="w-12 text-right outline-none bg-transparent text-xs tabular-nums" value={it.tax} onChange={e => updateItem(i, { tax: +e.target.value })} /></td>
                      <td className="py-1.5 px-2 text-right tabular-nums font-medium">{currency}{amount.toFixed(2)}</td>
                      <td className="py-1.5">
                        <button onClick={() => removeItem(i)} className="text-destructive/60 hover:text-destructive text-xs">×</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            <button onClick={addItem} className="text-xs text-primary hover:underline mb-4 block">+ Add row</button>

            {/* Totals */}
            <div className="flex justify-end mb-6">
              <div className="w-48 space-y-1 text-xs">
                <div className="flex justify-between"><span style={{ color: '#6b7280' }}>Subtotal</span><span className="tabular-nums">{currency}{subtotal.toFixed(2)}</span></div>
                <div className="flex justify-between"><span style={{ color: '#6b7280' }}>Tax</span><span className="tabular-nums">{currency}{totalTax.toFixed(2)}</span></div>
                <div className="flex justify-between font-bold text-sm pt-1" style={{ borderTop: '2px solid #1a1a2e' }}>
                  <span>Total</span><span className="tabular-nums">{currency}{grandTotal.toFixed(2)}</span>
                </div>
              </div>
            </div>

            {/* Footer */}
            {visible.filter(f => f.group === 'Footer').map(f => (
              <p key={f.key} contentEditable suppressContentEditableWarning onBlur={e => updateFieldValue(f.key, e.currentTarget.textContent || '')} className="text-xs outline-none mb-1" style={{ color: '#6b7280' }}>
                {f.value}
              </p>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
