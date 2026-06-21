import { useState, useMemo } from 'react';
import { format, subDays, startOfMonth, startOfQuarter, startOfYear, subMonths } from 'date-fns';
import { Search, CalendarIcon, FileText, ChevronLeft, ChevronRight } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Calendar } from '@/components/ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { mockOrders, getVendorSummaries } from '@/data/mockData';
import { useToast } from '@/hooks/use-toast';
import type { DateRange } from 'react-day-picker';

const ROWS = 20;
const today = new Date();
const PRESETS: { label: string; range: () => DateRange }[] = [
  { label: 'Today', range: () => ({ from: today, to: today }) },
  { label: 'Last 7 Days', range: () => ({ from: subDays(today, 7), to: today }) },
  { label: 'Last 30 Days', range: () => ({ from: subDays(today, 30), to: today }) },
  { label: 'Last Month', range: () => ({ from: startOfMonth(subMonths(today, 1)), to: subDays(startOfMonth(today), 1) }) },
  { label: 'MTD', range: () => ({ from: startOfMonth(today), to: today }) },
  { label: 'QTD', range: () => ({ from: startOfQuarter(today), to: today }) },
  { label: 'YTD', range: () => ({ from: startOfYear(today), to: today }) },
];

export default function Vendors() {
  const [search, setSearch] = useState('');
  const [dateRange, setDateRange] = useState<DateRange | undefined>();
  const [page, setPage] = useState(1);
  const [edits, setEdits] = useState<Record<string, { rate?: number; deductions?: number }>>({});
  const { toast } = useToast();

  const filteredOrders = useMemo(() => {
    return mockOrders.filter(o => {
      const d = new Date(o.created_at);
      return !dateRange?.from || (d >= dateRange.from && (!dateRange.to || d <= new Date(dateRange.to.getTime() + 86400000)));
    });
  }, [dateRange]);

  const vendors = useMemo(() => {
    const summaries = getVendorSummaries(filteredOrders);
    return summaries
      .map(v => {
        const e = edits[v.name];
        const rate = e?.rate ?? v.commission_rate;
        const deductions = e?.deductions ?? v.custom_deductions;
        const commission = Math.round(v.total_revenue * rate / 100 * 100) / 100;
        return { ...v, commission_rate: rate, custom_deductions: deductions, total_commission: commission, net_payable: Math.round((commission - deductions) * 100) / 100 };
      })
      .filter(v => !search || v.name.toLowerCase().includes(search.toLowerCase()));
  }, [filteredOrders, edits, search]);

  const totalPages = Math.ceil(vendors.length / ROWS);
  const rows = vendors.slice((page - 1) * ROWS, page * ROWS);

  const handleEditRate = (name: string, val: string) => {
    const num = parseFloat(val);
    if (!isNaN(num)) setEdits(prev => ({ ...prev, [name]: { ...prev[name], rate: num } }));
  };
  const handleEditDeductions = (name: string, val: string) => {
    const num = parseFloat(val);
    if (!isNaN(num)) setEdits(prev => ({ ...prev, [name]: { ...prev[name], deductions: num } }));
  };

  const handleGeneratePdf = (name: string) => {
    toast({ title: 'Invoice Generated', description: `PDF invoice for ${name} is ready.` });
  };

  return (
    <div className="space-y-4 animate-fade-in-up">
      <h1 className="text-2xl font-bold text-foreground">Vendors</h1>

      <div className="flex flex-wrap items-center gap-3">
        <div className="relative flex-1 min-w-[200px] max-w-sm">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
          <Input placeholder="Search vendors…" className="pl-9" value={search} onChange={e => { setSearch(e.target.value); setPage(1); }} />
        </div>
        <Popover>
          <PopoverTrigger asChild>
            <Button variant="outline" className="gap-2">
              <CalendarIcon className="h-4 w-4" />
              {dateRange?.from ? (
                <span className="text-xs">{format(dateRange.from, 'MMM d')} – {dateRange.to ? format(dateRange.to, 'MMM d') : '…'}</span>
              ) : 'Date range'}
            </Button>
          </PopoverTrigger>
          <PopoverContent className="w-auto p-0 flex" align="start">
            <div className="border-r p-2 space-y-1 min-w-[120px]">
              {PRESETS.map(p => (
                <button key={p.label} className="w-full text-left text-xs px-2 py-1.5 rounded hover:bg-muted transition-colors" onClick={() => { setDateRange(p.range()); setPage(1); }}>
                  {p.label}
                </button>
              ))}
              <button className="w-full text-left text-xs px-2 py-1.5 rounded text-destructive hover:bg-muted" onClick={() => setDateRange(undefined)}>Clear</button>
            </div>
            <Calendar mode="range" selected={dateRange} onSelect={v => { setDateRange(v); setPage(1); }} numberOfMonths={1} className="p-3 pointer-events-auto" />
          </PopoverContent>
        </Popover>
      </div>

      <div className="rounded-lg border bg-card shadow-sm overflow-auto">
        <Table>
          <TableHeader>
            <TableRow className="bg-muted/40">
              <TableHead className="text-xs">Vendor Name</TableHead>
              <TableHead className="text-xs text-right">Total Orders</TableHead>
              <TableHead className="text-xs text-right">Commission %</TableHead>
              <TableHead className="text-xs text-right">Total Commission</TableHead>
              <TableHead className="text-xs text-right">Deductions</TableHead>
              <TableHead className="text-xs text-right">Net Payable</TableHead>
              <TableHead className="text-xs text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((v, i) => (
              <TableRow key={v.name} className={i % 2 === 1 ? 'bg-muted/20' : ''}>
                <TableCell className="text-sm font-medium">{v.name}</TableCell>
                <TableCell className="text-sm text-right tabular-nums">{v.total_orders}</TableCell>
                <TableCell className="text-right">
                  <Input
                    type="number"
                    className="w-20 h-8 text-xs text-right ml-auto tabular-nums"
                    value={v.commission_rate}
                    onChange={e => handleEditRate(v.name, e.target.value)}
                    min={0} max={100} step={0.5}
                  />
                </TableCell>
                <TableCell className="text-sm text-right tabular-nums">${v.total_commission.toFixed(2)}</TableCell>
                <TableCell className="text-right">
                  <Input
                    type="number"
                    className="w-24 h-8 text-xs text-right ml-auto tabular-nums"
                    value={v.custom_deductions}
                    onChange={e => handleEditDeductions(v.name, e.target.value)}
                    min={0} step={1}
                  />
                </TableCell>
                <TableCell className={`text-sm text-right tabular-nums font-medium ${v.net_payable < 0 ? 'text-destructive' : ''}`}>
                  ${v.net_payable.toFixed(2)}
                </TableCell>
                <TableCell className="text-right">
                  <Button variant="outline" size="sm" className="gap-1 text-xs" onClick={() => handleGeneratePdf(v.name)}>
                    <FileText className="h-3 w-3" /> PDF
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 && (
              <TableRow><TableCell colSpan={7} className="text-center py-12 text-muted-foreground">No vendors found.</TableCell></TableRow>
            )}
          </TableBody>
        </Table>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>{vendors.length} vendor{vendors.length !== 1 ? 's' : ''}</span>
          <div className="flex items-center gap-1">
            <Button variant="outline" size="icon" className="h-8 w-8" disabled={page === 1} onClick={() => setPage(p => p - 1)}><ChevronLeft className="h-4 w-4" /></Button>
            <Button variant="outline" size="icon" className="h-8 w-8" disabled={page === totalPages} onClick={() => setPage(p => p + 1)}><ChevronRight className="h-4 w-4" /></Button>
          </div>
        </div>
      )}
    </div>
  );
}
