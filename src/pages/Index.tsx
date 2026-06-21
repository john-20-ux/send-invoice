import { Navigate } from 'react-router-dom';
import { useApp } from '@/contexts/AppContext';

export default function Index() {
  const { onboarded } = useApp();
  return <Navigate to={onboarded ? '/dashboard' : '/onboarding'} replace />;
}
