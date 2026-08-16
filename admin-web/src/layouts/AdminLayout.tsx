import { useMemo } from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { ProLayout, ProConfigProvider } from '@ant-design/pro-components';
import { Dropdown } from 'antd';
import {
  DashboardOutlined,
  KeyOutlined,
  TeamOutlined,
  DesktopOutlined,
  FileTextOutlined,
  ApartmentOutlined,
  UserSwitchOutlined,
  SettingOutlined,
  CloudUploadOutlined,
  UserOutlined,
  LogoutOutlined,
} from '@ant-design/icons';
import { useAuth } from '../context/AuthContext';

export default function AdminLayout() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const isSuper = user?.role === 'superadmin';

  const menuRoutes = useMemo(() => {
    const common = [
      { path: '/', name: '数据总览', icon: <DashboardOutlined /> },
      { path: '/cards', name: '卡密管理', icon: <KeyOutlined /> },
      { path: '/accounts', name: '账号管理', icon: <TeamOutlined /> },
      { path: '/devices', name: '设备管理', icon: <DesktopOutlined /> },
      {
        path: '/logs',
        name: isSuper ? '审计日志' : '操作日志',
        icon: <FileTextOutlined />,
      },
    ];
    const superOnly = isSuper
      ? [
          { path: '/channels', name: '渠道管理', icon: <ApartmentOutlined /> },
          { path: '/agents', name: '代理管理', icon: <UserSwitchOutlined /> },
          { path: '/settings', name: '客户端配置', icon: <SettingOutlined /> },
          { path: '/releases', name: '安装包发布', icon: <CloudUploadOutlined /> },
        ]
      : [];
    return [...common, ...superOnly];
  }, [isSuper]);

  const onMenuClick = (path?: string) => {
    if (path) navigate(path);
  };

  const onLogout = async () => {
    try {
      await logout();
    } finally {
      navigate('/login', { replace: true });
    }
  };

  const actionMenu = {
    items: [
      {
        key: 'logout',
        icon: <LogoutOutlined />,
        label: '退出登录',
        onClick: onLogout,
      },
    ],
  };

  return (
    <ProConfigProvider hashed={false}>
      <ProLayout
        title="快码运营管理"
        logo={false}
        layout="mix"
        fixedHeader
        fixSiderbar
        siderWidth={200}
        route={{ path: '/', routes: menuRoutes }}
        location={{ pathname: location.pathname }}
        menuItemRender={(item, dom) => (
          <div onClick={() => onMenuClick(item.path)}>{dom}</div>
        )}
        avatarProps={{
          icon: <UserOutlined />,
          size: 'small',
          title: user?.username || '用户',
          render: (_props, dom) => (
            <Dropdown menu={actionMenu} placement="bottomRight">
              {dom}
            </Dropdown>
          ),
        }}
        actionsRender={() => []}
        onMenuHeaderClick={() => navigate('/')}
      >
        <Outlet />
      </ProLayout>
    </ProConfigProvider>
  );
}
