import { useEffect, useState } from 'react';
import {
  App,
  Button,
  Card,
  Form,
  Input,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
  Upload,
} from 'antd';
import { InboxOutlined, ReloadOutlined } from '@ant-design/icons';
import type { UploadFile } from 'antd/es/upload/interface';
import { listReleases, uploadRelease } from '../api';
import { formatBytes, formatTime } from '../utils/format';
import type { ReleaseFile } from '../types';

export default function Releases() {
  const { message } = App.useApp();
  const [files, setFiles] = useState<ReleaseFile[]>([]);
  const [latestUrl, setLatestUrl] = useState('');
  const [loading, setLoading] = useState(false);
  const [fileList, setFileList] = useState<UploadFile[]>([]);
  const [version, setVersion] = useState('');
  const [forceUpdate, setForceUpdate] = useState(false);
  const [uploading, setUploading] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      const d = await listReleases();
      setFiles(d.files);
      setLatestUrl(d.latestUrl);
    } catch (e) {
      message.error((e as Error)?.message || '加载安装包失败');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const beforeUpload = (file: File) => {
    const lower = file.name.toLowerCase();
    if (!lower.endsWith('.exe')) {
      message.error('只允许上传 .exe 安装包');
      return Upload.LIST_IGNORE;
    }
    if (file.size > 80 * 1024 * 1024) {
      message.error('安装包不能超过 80MB');
      return Upload.LIST_IGNORE;
    }
    setFileList([{ uid: '-1', name: file.name, size: file.size, originFileObj: file } as UploadFile]);
    return false;
  };

  const onUpload = async () => {
    if (!fileList[0]?.originFileObj) {
      message.warning('请先选择安装包');
      return;
    }
    if (!/^\d+\.\d+\.\d+$/.test(version)) {
      message.warning('版本号格式应为 x.y.z');
      return;
    }
    setUploading(true);
    try {
      const r = await uploadRelease(fileList[0].originFileObj, version.trim(), forceUpdate);
      message.success(`已发布 v${r.version}（${formatBytes(r.size)}）`);
      setFileList([]);
      setVersion('');
      setForceUpdate(false);
      load();
    } catch (e) {
      message.error((e as Error)?.message || '上传失败');
    } finally {
      setUploading(false);
    }
  };

  const columns = [
    { title: '文件名', dataIndex: 'name', ellipsis: true },
    { title: '大小', dataIndex: 'size', width: 120, render: (v: number) => formatBytes(v) },
    { title: '更新时间', dataIndex: 'updatedAt', width: 180, render: (v: string) => formatTime(v) },
    {
      title: '下载',
      dataIndex: 'url',
      width: 320,
      render: (v: string) => (
        <Space>
          <Typography.Text copyable style={{ fontFamily: 'monospace', fontSize: 12 }}>
            {v}
          </Typography.Text>
          <a href={v} target="_blank" rel="noreferrer">
            打开
          </a>
        </Space>
      ),
    },
  ];

  return (
    <div>
      <Card
        title="发布新版本"
        style={{ maxWidth: 720 }}
        extra={
          <Tag color="blue">
            当前最新：{files[0]?.name ?? '未发布'}
          </Tag>
        }
      >
        <Form layout="vertical">
          <Form.Item label="安装包（.exe，最大 80MB）" required>
            <Upload.Dragger
              multiple={false}
              maxCount={1}
              accept=".exe"
              fileList={fileList}
              beforeUpload={beforeUpload}
              onRemove={() => setFileList([])}
            >
              <p className="ant-upload-drag-icon">
                <InboxOutlined />
              </p>
              <p className="ant-upload-text">点击或拖拽 .exe 到此处</p>
            </Upload.Dragger>
          </Form.Item>
          <Form.Item label="版本号" required extra="格式 x.y.z，如 1.0.5">
            <Input
              placeholder="1.0.5"
              style={{ width: 200 }}
              value={version}
              onChange={(e) => setVersion(e.target.value)}
            />
          </Form.Item>
          <Form.Item label="是否强制升级">
            <Switch
              checked={forceUpdate}
              onChange={setForceUpdate}
              checkedChildren="强制"
              unCheckedChildren="提示"
            />
            <span style={{ marginLeft: 8, color: '#8c8c8c' }}>
              {forceUpdate ? '旧客户端将被强制升级' : '仅提示有新版'}
            </span>
          </Form.Item>
          <Space>
            <Button type="primary" loading={uploading} onClick={onUpload}>
              发布
            </Button>
            <Button icon={<ReloadOutlined />} onClick={load}>
              刷新
            </Button>
          </Space>
        </Form>
        <Typography.Paragraph type="secondary" style={{ marginTop: 12 }}>
          发布后客户端 <code>/config</code> 将立即返回新版本；最新版可通过{' '}
          <Typography.Text copyable>{latestUrl}</Typography.Text> 下载。
        </Typography.Paragraph>
      </Card>

      <Card title="历史安装包" style={{ marginTop: 16 }}>
        <Table<ReleaseFile>
          rowKey="name"
          loading={loading}
          dataSource={files}
          columns={columns}
          size="middle"
          pagination={false}
        />
      </Card>
    </div>
  );
}
