import type { ShopifyOrder } from '@/types/shopify';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Separator } from '@/components/ui/separator';

interface OrderDetailModalProps {
  order: ShopifyOrder | null;
  open: boolean;
  onClose: () => void;
}

export function OrderDetailModal({ order, open, onClose }: OrderDetailModalProps) {
  if (!order) return null;

  const subtotal = order.line_items.reduce((sum, li) => sum + li.totalAmount, 0);

  return (
    <Dialog open={open} onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-3">
            <span>Order {order.name}</span>
            <Badge variant={order.fully_paid ? 'default' : 'secondary'} className="text-xs">
              {order.financial_status}
            </Badge>
            {order.fulfillment_status && (
              <Badge variant="outline" className="text-xs">
                {order.fulfillment_status}
              </Badge>
            )}
          </DialogTitle>
        </DialogHeader>

        {/* Customer */}
        <div className="text-sm text-muted-foreground">
          {order.customer_first_name} {order.customer_last_name}
          {order.customer_email && <span> · {order.customer_email}</span>}
        </div>

        {/* Line Items */}
        <div className="mt-4">
          <h3 className="text-sm font-semibold mb-2">Line Items</h3>
          <div className="rounded-md border overflow-auto">
            <Table>
              <TableHeader>
                <TableRow className="bg-muted/40">
                  <TableHead className="text-xs">SKU</TableHead>
                  <TableHead className="text-xs">Product</TableHead>
                  <TableHead className="text-xs">Variant</TableHead>
                  <TableHead className="text-xs">Vendor</TableHead>
                  <TableHead className="text-xs text-right">Qty</TableHead>
                  <TableHead className="text-xs text-right">Current Qty</TableHead>
                  <TableHead className="text-xs text-right">Total</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {order.line_items.map((li, idx) => (
                  <TableRow key={li.id || idx}>
                    <TableCell className="text-xs font-mono">{li.sku || '—'}</TableCell>
                    <TableCell className="text-xs">{li.title}</TableCell>
                    <TableCell className="text-xs">{li.variantTitle || '—'}</TableCell>
                    <TableCell className="text-xs">{li.vendor || '—'}</TableCell>
                    <TableCell className="text-xs text-right">{li.quantity}</TableCell>
                    <TableCell className="text-xs text-right">{li.currentQuantity}</TableCell>
                    <TableCell className="text-xs text-right tabular-nums">
                      ${li.totalAmount.toFixed(2)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </div>

        {/* Totals */}
        <div className="mt-4">
          <h3 className="text-sm font-semibold mb-2">Order Totals</h3>
          <div className="rounded-md border p-4 space-y-2 text-sm">
            <TotalRow label="Subtotal" value={subtotal} currency={order.total_price_currency} />
            <TotalRow label="Discounts" value={-order.total_discounts_amount} currency={order.total_price_currency} />
            <TotalRow label="Shipping" value={order.total_shipping_amount} currency={order.total_price_currency} />
            <TotalRow label="Tax" value={order.total_tax_amount} currency={order.total_price_currency} />
            {order.total_tip_amount > 0 && (
              <TotalRow label="Tips" value={order.total_tip_amount} currency={order.total_price_currency} />
            )}
            <Separator />
            <TotalRow label="Total" value={order.total_price_amount} currency={order.total_price_currency} bold />
            {order.total_refunded_amount > 0 && (
              <TotalRow label="Refunded" value={-order.total_refunded_amount} currency={order.total_price_currency} destructive />
            )}
          </div>
        </div>

        {/* Transactions */}
        {order.transactions.length > 0 && (
          <div className="mt-4">
            <h3 className="text-sm font-semibold mb-2">Transactions</h3>
            <div className="rounded-md border p-4 space-y-1">
              {order.transactions.map((t, idx) => (
                <div key={idx} className="flex items-center justify-between text-sm">
                  <span className="text-muted-foreground">Transaction {idx + 1}</span>
                  <span className={`tabular-nums font-medium ${t.amount < 0 ? 'text-destructive' : ''}`}>
                    {t.amount < 0 ? '-' : ''}${Math.abs(t.amount).toFixed(2)} {t.currency}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

function TotalRow({ label, value, currency, bold, destructive }: {
  label: string;
  value: number;
  currency: string;
  bold?: boolean;
  destructive?: boolean;
}) {
  return (
    <div className="flex items-center justify-between">
      <span className={`${bold ? 'font-semibold' : 'text-muted-foreground'}`}>{label}</span>
      <span className={`tabular-nums ${bold ? 'font-semibold' : ''} ${destructive ? 'text-destructive' : ''}`}>
        {value < 0 ? '-' : ''}${Math.abs(value).toFixed(2)} {currency}
      </span>
    </div>
  );
}
