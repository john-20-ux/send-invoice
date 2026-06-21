import {
  Home, ShoppingCart, Users, FileText, Bell, Settings, HelpCircle, Heart,
} from 'lucide-react';
import { NavLink } from '@/components/NavLink';
import { useLocation } from 'react-router-dom';
import {
  Sidebar, SidebarContent, SidebarGroup, SidebarGroupContent,
  SidebarMenu, SidebarMenuButton, SidebarMenuItem, useSidebar,
} from '@/components/ui/sidebar';

const NAV_ITEMS = [
  { title: 'Home', url: '/dashboard', icon: Home },
  { title: 'Orders', url: '/orders', icon: ShoppingCart },
  { title: 'Vendors', url: '/vendors', icon: Users },
  { title: 'Invoice Templates', url: '/invoice-templates', icon: FileText },
  { title: 'Notifications', url: '/notifications', icon: Bell },
  { title: 'Settings', url: '/settings', icon: Settings },
  { title: 'Support', url: '/support', icon: HelpCircle },
];

export function AppSidebar() {
  const { state } = useSidebar();
  const collapsed = state === 'collapsed';
  const location = useLocation();

  return (
    <Sidebar collapsible="icon">
      <SidebarContent>
        <div className="flex items-center gap-2 px-4 py-5 border-b border-sidebar-border">
          <Heart className="h-6 w-6 text-primary shrink-0" fill="currentColor" />
          {!collapsed && (
            <span className="text-lg font-bold tracking-tight text-foreground">
              Lovable
            </span>
          )}
        </div>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {NAV_ITEMS.map((item) => {
                const isActive = location.pathname === item.url ||
                  (item.url !== '/dashboard' && location.pathname.startsWith(item.url));
                return (
                  <SidebarMenuItem key={item.title}>
                    <SidebarMenuButton asChild isActive={isActive}>
                      <NavLink
                        to={item.url}
                        end={item.url === '/dashboard'}
                        className="hover:bg-sidebar-accent/60"
                        activeClassName="bg-sidebar-accent text-primary font-medium"
                      >
                        <item.icon className="mr-2 h-4 w-4 shrink-0" />
                        {!collapsed && <span>{item.title}</span>}
                      </NavLink>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
    </Sidebar>
  );
}
