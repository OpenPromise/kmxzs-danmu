import { Navigate, Route, Routes } from 'react-router-dom';
import { Spin } from 'antd';
import { useAuth } from './context/AuthContext';
import AdminLayout from './layouts/AdminLayout';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Cards from './pages/Cards';
import Accounts from './pages/Accounts';
import Devices from './pages/Devices';
import Logs from './pages/Logs';
import Channels from './pages/Channels';
import Agents from './pages/Agents';
import Settings from './pages/Settings';
import Releases from './pages/Releases';
import { ReactElement } from 'react';

function RequireAuth({ children }: { children: ReactElement }) {
  const { user, loading } = useAuth();
  if (loading) {
    return <Spin size="large" style={{ display: 'block', margin: '240px auto' }} />;
  }
  if (!user) return <Navigate to="/login" replace />;
  return children;
}

export default function App() {
  const { user } = useAuth();
  const isSuper = user?.role === 'superadmin';

  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route
        path="/"
        element={
          <RequireAuth>
            <AdminLayout />
          </RequireAuth>
        }
      >
        <Route index element={<Dashboard />} />
        <Route path="cards" element={<Cards />} />
        <Route path="accounts" element={<Accounts />} />
        <Route path="devices" element={<Devices />} />
        <Route path="logs" element={<Logs />} />
        {isSuper && (
          <>
            <Route path="channels" element={<Channels />} />
            <Route path="agents" element={<Agents />} />
            <Route path="settings" element={<Settings />} />
            <Route path="releases" element={<Releases />} />
          </>
        )}
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
