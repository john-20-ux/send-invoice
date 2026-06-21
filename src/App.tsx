import { Suspense, lazy } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { AppProvider } from "@/contexts/AppContext";
import { AppLayout } from "@/components/layout/AppLayout";

const Index = lazy(() => import("./pages/Index"));
const Onboarding = lazy(() => import("./pages/Onboarding"));
const Dashboard = lazy(() => import("./pages/Dashboard"));
const Orders = lazy(() => import("./pages/Orders"));
const Vendors = lazy(() => import("./pages/Vendors"));
const InvoiceTemplates = lazy(() => import("./pages/InvoiceTemplates"));
const Notifications = lazy(() => import("./pages/Notifications"));
const Settings = lazy(() => import("./pages/Settings"));
const Plans = lazy(() => import("./pages/Plans"));
const Support = lazy(() => import("./pages/Support"));
const NotFound = lazy(() => import("./pages/NotFound"));

const queryClient = new QueryClient();

function PageFallback() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="text-sm text-muted-foreground">Loading…</div>
    </div>
  );
}

function withSuspense(element: React.ReactNode) {
  return <Suspense fallback={<PageFallback />}>{element}</Suspense>;
}

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Toaster />
      <Sonner />
      <AppProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/" element={withSuspense(<Index />)} />
            <Route path="/onboarding" element={withSuspense(<Onboarding />)} />
            <Route path="/onboarding/step-1" element={withSuspense(<Onboarding />)} />
            <Route path="/onboarding/step-2" element={withSuspense(<Onboarding />)} />
            <Route path="/onboarding/step-3" element={withSuspense(<Onboarding />)} />
            <Route path="/dashboard" element={withSuspense(<AppLayout><Dashboard /></AppLayout>)} />
            <Route path="/orders" element={withSuspense(<AppLayout><Orders /></AppLayout>)} />
            <Route path="/vendors" element={withSuspense(<AppLayout><Vendors /></AppLayout>)} />
            <Route path="/invoice-templates" element={withSuspense(<AppLayout><InvoiceTemplates /></AppLayout>)} />
            <Route path="/notifications" element={withSuspense(<AppLayout><Notifications /></AppLayout>)} />
            <Route path="/settings" element={withSuspense(<AppLayout><Settings /></AppLayout>)} />
            <Route path="/settings/plans" element={withSuspense(<AppLayout><Plans /></AppLayout>)} />
            <Route path="/support" element={withSuspense(<AppLayout><Support /></AppLayout>)} />
            <Route path="*" element={withSuspense(<NotFound />)} />
          </Routes>
        </BrowserRouter>
      </AppProvider>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
