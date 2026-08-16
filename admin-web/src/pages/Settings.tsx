import { useEffect, useState } from 'react';
import { App, Button, Card, Descriptions, Form, Input, Switch, Typography } from 'antd';
import { SaveOutlined } from '@ant-design/icons';
import { getSettings, updateSettings } from '../api';
import { formatTime } from '../utils/format';
import type { PublicConfig } from '../types';

export default function Settings() {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const [saving, setSaving] = useState(false);
  const [publicCfg, setPublicCfg] = useState<PublicConfig | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Record<string, string>>({});

  useEffect(() => {
    getSettings()
      .then((data) => {
        const s = data.settings;
        form.setFieldsValue({
          notice: s.notice?.value ?? '',
          client_version: s.client_version?.value ?? '',
          force_update: s.force_update?.value === '1',
          min_client_version: s.min_client_version?.value ?? '',
        });
        setPublicCfg(data.public);
        setUpdatedAt(
          Object.fromEntries(
            Object.entries(s).map(([k, v]) => [k, v.updatedAt])
          )
        );
      })
      .catch((e) => message.error((e as Error)?.message || '加载配置失败'));
  }, []);

  const onSave = async () => {
    const v = await form.validateFields();
    setSaving(true);
    try {
      const pub = await updateSettings({
        notice: v.notice,
        client_version: v.client_version,
        force_update: v.force_update,
        min_client_version: v.min_client_version,
      });
      setPublicCfg(pub);
      message.success('配置已保存，客户端下次获取配置即生效');
    } catch (e) {
      message.error((e as Error)?.message || '保存失败');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div>
      <Card title="客户端配置" style={{ maxWidth: 720 }}>
        <Form form={form} layout="vertical">
          <Form.Item
            name="notice"
            label="公告"
            extra="客户端首页展示的文字（多行）"
          >
            <Input.TextArea rows={4} maxLength={500} showCount placeholder="欢迎使用直播小助手" />
          </Form.Item>
          <Form.Item
            name="client_version"
            label="客户端版本号"
            extra="发布安装包时后端会自动更新；此处可手动改提示版本"
            rules={[{ pattern: /^\d+\.\d+\.\d+$/, message: '格式应为 x.y.z' }]}
          >
            <Input placeholder="1.0.0" style={{ width: 200 }} />
          </Form.Item>
          <Form.Item
            name="min_client_version"
            label="最低客户端版本"
            extra="低于该版本的客户端会被提示升级"
            rules={[{ pattern: /^\d+\.\d+\.\d+$/, message: '格式应为 x.y.z' }]}
          >
            <Input placeholder="1.0.0" style={{ width: 200 }} />
          </Form.Item>
          <Form.Item name="force_update" label="强制升级" valuePropName="checked">
            <Switch checkedChildren="强制" unCheckedChildren="提示" />
          </Form.Item>
          <Button type="primary" icon={<SaveOutlined />} loading={saving} onClick={onSave}>
            保存配置
          </Button>
        </Form>
      </Card>

      {publicCfg && (
        <Card title="当前下发配置" style={{ marginTop: 16, maxWidth: 720 }}>
          <Descriptions
            size="small"
            bordered
            column={2}
            items={[
              { key: 'version', label: '版本号', children: publicCfg.version },
              { key: 'minVersion', label: '最低版本', children: publicCfg.minVersion },
              { key: 'force', label: '强制升级', children: publicCfg.force ? '是' : '否' },
              { key: 'size', label: '安装包大小', children: `${(publicCfg.downloadSize / 1024 / 1024).toFixed(1)} MB` },
              { key: 'notice', label: '公告', span: 2, children: publicCfg.notice },
              { key: 'download', label: '下载地址', span: 2, children: <Typography.Text copyable>{publicCfg.download}</Typography.Text> },
            ]}
          />
          {updatedAt['notice'] && (
            <Typography.Text type="secondary" style={{ marginTop: 8, display: 'block' }}>
              最近更新：{formatTime(updatedAt['notice'])}
            </Typography.Text>
          )}
        </Card>
      )}
    </div>
  );
}
