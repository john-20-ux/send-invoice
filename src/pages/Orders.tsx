import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { format, subDays } from 'date-fns';
import { Search, RefreshCw, CalendarIcon, ChevronLeft, ChevronRight } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Calendar } from '@/components/ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useToast } from '@/hooks/use-toast';
import { useApp } from '@/contexts/AppContext';
import { api } from '@/services/api';
import { OrderDetailModal } from '@/components/orders/OrderDetailModal';
import type { ShopifyOrder } from '@/types/shopify';
import type { DateRange } from 'react-day-picker';

const LIMIT = 25;

const PRESETS: { label: string; range: () => DateRange }[] = [
  { label: 'Last 7 Days', range: () => ({ from: subDays(new Date(), 7), to: new Date() }) },
  { label: 'Last 30 Days', range: () => ({ from: subDays(new Date(), 30), to: new Date() }) },
  { label: 'Last 90 Days', range: () => ({ from: subDays(new Date(), 90), to: new Date() }) },
];

function financialBadgeVariant(status: string): 'default' | 'secondary' | 'destructive' | 'outline' {
  switch (status) {
    case 'PAID': return 'default';
    case 'PARTIALLY_PAID': return 'secondary';
    case 'REFUNDED':
    case 'PARTIALLY_REFUNDED': return 'destructive';
    default: return 'outline';
  }
}

function fulfillmentBadgeVariant(status: string | null): 'default' | 'secondary' | 'outline' {
  switch (status) {
    case 'FULFILLED': return 'default';
    case 'PARTIALLY_FULFILLED':
    case 'IN_PROGRESS': return 'secondary';
    default: return 'outline';
  }
}

export default function Orders() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState('');
  const [dateRange, setDateRange] = useState<DateRange | undefined>(() => ({
    from: subDays(new Date(), 30),
    to: new Date(),
  }));
  const [page, setPage] = useState(1);
  const [orders, setOrders] = useState<ShopifyOrder[]>([]);
  const [total, setTotal] = useState(0);
  const [totalPages, setTotalPages] = useState(0);
  const [loading, setLoading] = useState(true);
  const [selectedOrder, setSelectedOrder] = useState<ShopifyOrder | null>(null);
  const { syncing, triggerSync, syncStatus } = useApp();
  const { toast } = useToast();

  // Sync query params
  useEffect(() => {
    const from = searchParams.get('from');
    const to = searchParams.get('to');
    if (from && to) {
      setDateRange({ from: new Date(from), to: new Date(to) });
    }
  }, [searchParams]);

  const fetchOrders = useCallback(async () => {
    setLoading(true);
    try {
      const result = await api.getOrders({
        from: dateRange?.from ? format(dateRange.from, 'yyyy-MM-dd') : undefined,
        to: dateRange?.to ? format(dateRange.to, 'yyyy-MM-dd') : undefined,
        page,
        limit: LIMIT,
        search: search || undefined,
      });
      setOrders(result.orders);
      setTotal(result.total);
      setTotalPages(result.totalPages);
    } finally {
      setLoading(false);
    }
  }, [dateRange, page, search]);

  useEffect(() => {
    fetchOrders();
  }, [fetchOrders]);

  // Refresh orders when sync completes
  useEffect(() => {
    if (syncStatus.status === 'completed') {
      fetchOrders();
    }
  }, [fetchOrders, syncStatus.status]);

  const handleDateChange = (range: DateRange | undefined) => {
    setDateRange(range);
    setPage(1);
    if (range?.from && range?.to) {
      setSearchParams({
        from: format(range.from, 'yyyy-MM-dd'),
        to: format(range.to, 'yyyy-MM-dd'),
      });
    } else {
      setSearchParams({});
    }
  };

  const handleSync = async () => {
    const result = await triggerSync('incremental');
    if (!result.started) {
      toast({ title: 'Sync unavailable', description: result.message || 'Try again later.', variant: 'destructive' });
    } else {
      toast({ title: 'Sync started', description: 'Orders are being synced from Shopify.' });
    }
  };

  const handleSearch = (value: string) => {
    setSearch(value);
    setPage(1);
  };

  return (
    <div className="space-y-4 animate-fade-in-up">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-foreground">Orders</h1>
        <Button onClick={handleSync} disabled={syncing} className="gap-2">
          <RefreshCw className={`h-4 w-4 ${syncing ? 'animate-spin' : ''}`} />
          {syncing ? 'Syncing…' : 'Sync Orders'}
        </Button>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap items-center gap-3">
        <div className="relative flex-1 min-w-[200px] max-w-sm">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Search by name, email…"
            className="pl-9"
            value={search}
            onChange={e => handleSearch(e.target.value)}
          />
        </div>

        <Popover>
          <PopoverTrigger asChild>
            <Button variant="outline" className="gap-2">
              <CalendarIcon className="h-4 w-4" />
              {dateRange?.from ? (
                <span className="text-xs">
                  {format(dateRange.from, 'MMM d')} – {dateRange.to ? format(dateRange.to, 'MMM d') : '…'}
                </span>
              ) : 'Date range'}
            </Button>
          </PopoverTrigger>
          <PopoverContent className="w-auto p-0 flex" align="start">
            <div className="border-r p-2 space-y-1 min-w-[130px]">
              {PRESETS.map(p => (
                <button
                  key={p.label}
                  className="w-full text-left text-xs px-2 py-1.5 rounded hover:bg-muted transition-colors"
                  onClick={() => handleDateChange(p.range())}
                >
                  {p.label}
                </button>
              ))}
              <button
                className="w-full text-left text-xs px-2 py-1.5 rounded text-destructive hover:bg-muted transition-colors"
                onClick={() => handleDateChange(undefined)}
              >
                Clear
              </button>
            </div>
            <Calendar
              mode="range"
              selected={dateRange}
              onSelect={v => handleDateChange(v)}
              numberOfMonths={1}
              className="p-3 pointer-events-auto"
            />
          </PopoverContent>
        </Popover>

        <span className="text-xs text-muted-foreground">{total} orders</span>
      </div>

      {/* Orders Table */}
      <div className="rounded-lg border bg-card shadow-sm overflow-auto">
        <Table>
          <TableHeader>
            <TableRow className="bg-muted/40">
              <TableHead className="text-xs">Order</TableHead>
              <TableHead className="text-xs">Date</TableHead>
              <TableHead className="text-xs">Customer</TableHead>
              <TableHead className="text-xs">Email</TableHead>
              <TableHead className="text-xs text-right">Items</TableHead>
              <TableHead className="text-xs text-right">Total</TableHead>
              <TableHead className="text-xs">Payment</TableHead>
              <TableHead className="text-xs">Fulfillment</TableHead>
              <TableHead className="text-xs text-center">Paid</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {loading && orders.length === 0 ? (
              <TableRow>
                <TableCell colSpan={9} className="text-center py-12 text-muted-foreground">
                  Loading orders…
                </TableCell>
              </TableRow>
            ) : orders.length === 0 ? (
              <TableRow>
                <TableCell colSpan={9} className="text-center py-12 text-muted-foreground">
                  No orders match your filters.
                </TableCell>
              </TableRow>
            ) : (
              orders.map((o, i) => (
                <TableRow
                  key={o.id}
                  className={`cursor-pointer hover:bg-muted/40 transition-colors ${i % 2 === 1 ? 'bg-muted/20' : ''}`}
                  onClick={() => setSelectedOrder(o)}
                >
                  <TableCell className="text-sm font-medium">{o.name}</TableCell>
                  <TableCell className="text-sm tabular-nums">
                    {format(new Date(o.created_at), 'MMM d, yyyy')}
                  </TableCell>
                  <TableCell className="text-sm">
                    {o.customer_first_name} {o.customer_last_name}
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground truncate max-w-[180px]">
                    {o.customer_email || '—'}
                  </TableCell>
                  <TableCell className="text-sm text-right tabular-nums">
                    {o.line_items.length}
                  </TableCell>
                  <TableCell className="text-sm text-right tabular-nums font-medium">
                    ${o.total_price_amount.toFixed(2)} {o.total_price_currency}
                  </TableCell>
                  <TableCell>
                    <Badge variant={financialBadgeVariant(o.financial_status)} className="text-[10px]">
                      {o.financial_status}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    {o.fulfillment_status ? (
                      <Badge variant={fulfillmentBadgeVariant(o.fulfillment_status)} className="text-[10px]">
                        {o.fulfillment_status}
                      </Badge>
                    ) : (
                      <Badge variant="outline" className="text-[10px]">UNFULFILLED</Badge>
                    )}
                  </TableCell>
                  <TableCell className="text-center">
                    {o.fully_paid ? (
                      <Badge variant="default" className="text-[10px] bg-green-600">Yes</Badge>
                    ) : (
                      <Badge variant="outline" className="text-[10px]">No</Badge>
                    )}
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>
            Showing {(page - 1) * LIMIT + 1}–{Math.min(page * LIMIT, total)} of {total}
          </span>
          <div className="flex items-center gap-1">
            <Button
              variant="outline"
              size="icon"
              className="h-8 w-8"
              disabled={page === 1}
              onClick={() => setPage(p => p - 1)}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            {Array.from({ length: Math.min(totalPages, 7) }, (_, i) => {
              let p: number;
              if (totalPages <= 7) {
                p = i + 1;
              } else if (page <= 4) {
                p = i + 1;
              } else if (page >= totalPages - 3) {
                p = totalPages - 6 + i;
              } else {
                p = page - 3 + i;
              }
              return (
                <Button
                  key={p}
                  variant={p === page ? 'default' : 'outline'}
                  size="icon"
                  className="h-8 w-8 text-xs"
                  onClick={() => setPage(p)}
                >
                  {p}
                </Button>
              );
            })}
            <Button
              variant="outline"
              size="icon"
              className="h-8 w-8"
              disabled={page === totalPages}
              onClick={() => setPage(p => p + 1)}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      )}

      {/* Order Detail Modal */}
      <OrderDetailModal
        order={selectedOrder}
        open={!!selectedOrder}
        onClose={() => setSelectedOrder(null)}
      />
    </div>
  );
}
