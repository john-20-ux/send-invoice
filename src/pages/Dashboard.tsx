import { useMemo, useState, useEffect } from 'react';
import { ShoppingCart, DollarSign, CreditCard, TrendingUp } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from 'recharts';
import { api } from '@/services/api';
import type { ShopifyOrder } from '@/types/shopify';
import { format, subDays } from 'date-fns';

export default function Dashboard() {
  const [orders, setOrders] = useState<ShopifyOrder[]>([]);
  const [chartTab, setChartTab] = useState('daily');

  useEffect(() => {
    api.getOrders({ limit: 1000 }).then(res => setOrders(res.orders));
  }, []);

  const stats = useMemo(() => {
    const totalOrders = orders.length;
    const totalRevenue = orders.reduce((s, o) => s + o.total_price_amount, 0);
    const paidOrders = orders.filter(o => o.fully_paid).length;
    const fulfilled = orders.filter(o => o.fulfillment_status === 'FULFILLED').length;
    return { totalOrders, totalRevenue, paidOrders, fulfilled };
  }, [orders]);

  const dailyData = useMemo(() => {
    const map = new Map<string, { revenue: number; count: number }>();
    const last30 = subDays(new Date(), 30);
    orders.filter(o => new Date(o.created_at) >= last30).forEach(o => {
      const day = format(new Date(o.created_at), 'yyyy-MM-dd');
      const entry = map.get(day) || { revenue: 0, count: 0 };
      entry.revenue += o.total_price_amount;
      entry.count++;
      map.set(day, entry);
    });
    return Array.from(map.entries())
      .map(([date, data]) => ({ date, ...data }))
      .sort((a, b) => a.date.localeCompare(b.date));
  }, [orders]);

  const statusData = useMemo(() => {
    const map = new Map<string, number>();
    orders.forEach(o => {
      const status = o.financial_status;
      map.set(status, (map.get(status) || 0) + 1);
    });
    return Array.from(map.entries())
      .map(([status, count]) => ({ status, count }))
      .sort((a, b) => b.count - a.count);
  }, [orders]);

  const STAT_CARDS = [
    { label: 'Total Orders', value: stats.totalOrders.toLocaleString(), icon: ShoppingCart },
    { label: 'Total Revenue', value: `$${stats.totalRevenue.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`, icon: DollarSign },
    { label: 'Paid Orders', value: stats.paidOrders.toLocaleString(), icon: CreditCard },
    { label: 'Fulfilled', value: stats.fulfilled.toLocaleString(), icon: TrendingUp },
  ];

  return (
    <div className="space-y-6 animate-fade-in-up">
      <h1 className="text-2xl font-bold text-foreground">Dashboard</h1>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {STAT_CARDS.map((s, i) => (
          <Card key={s.label} className="shadow-sm" style={{ animationDelay: `${i * 80}ms` }}>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium text-muted-foreground">{s.label}</CardTitle>
              <s.icon className="h-5 w-5 text-primary" />
            </CardHeader>
            <CardContent>
              <p className="text-2xl font-bold tabular-nums text-card-foreground">{s.value}</p>
            </CardContent>
          </Card>
        ))}
      </div>

      <Card className="shadow-sm">
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-base">Orders Overview</CardTitle>
          <Tabs value={chartTab} onValueChange={setChartTab}>
            <TabsList className="h-8">
              <TabsTrigger value="daily" className="text-xs px-3 h-7">Daily Revenue</TabsTrigger>
              <TabsTrigger value="status" className="text-xs px-3 h-7">By Status</TabsTrigger>
            </TabsList>
          </Tabs>
        </CardHeader>
        <CardContent>
          <div className="h-64">
            {chartTab === 'daily' ? (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={dailyData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="hsl(214,20%,90%)" />
                  <XAxis dataKey="date" tick={{ fontSize: 11 }} tickFormatter={d => d.slice(5)} />
                  <YAxis tick={{ fontSize: 11 }} tickFormatter={v => `$${v}`} />
                  <Tooltip
                    contentStyle={{ borderRadius: 8, border: '1px solid hsl(214,20%,90%)', fontSize: 12 }}
                    formatter={(value: number) => [`$${value.toFixed(2)}`, 'Revenue']}
                  />
                  <Bar dataKey="revenue" fill="hsl(213,94%,48%)" radius={[4, 4, 0, 0]} name="Revenue" />
                </BarChart>
              </ResponsiveContainer>
            ) : (
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={statusData} layout="vertical">
                  <CartesianGrid strokeDasharray="3 3" stroke="hsl(214,20%,90%)" />
                  <XAxis type="number" tick={{ fontSize: 11 }} allowDecimals={false} />
                  <YAxis type="category" dataKey="status" tick={{ fontSize: 11 }} width={140} />
                  <Tooltip
                    contentStyle={{ borderRadius: 8, border: '1px solid hsl(214,20%,90%)', fontSize: 12 }}
                  />
                  <Bar dataKey="count" fill="hsl(158,64%,40%)" radius={[0, 4, 4, 0]} name="Orders" />
                </BarChart>
              </ResponsiveContainer>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
