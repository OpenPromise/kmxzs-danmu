import { App, Button } from 'antd';
import { CopyOutlined } from '@ant-design/icons';

/** 兼容 HTTP 环境的复制：非 secure context 下 navigator.clipboard 不可用，回退 execCommand。 */
function legacyCopy(text: string): boolean {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.left = '-9999px';
  ta.setAttribute('readonly', '');
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand('copy');
  } catch {
    ok = false;
  }
  document.body.removeChild(ta);
  return ok;
}

export default function CopyButton({ text, label }: { text: string; label?: string }) {
  const { message } = App.useApp();
  const onCopy = async () => {
    let ok = false;
    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text);
        ok = true;
      } catch {
        ok = false;
      }
    }
    if (!ok) ok = legacyCopy(text);
    if (ok) message.success('已复制');
    else message.error('复制失败，请手动选择复制');
  };
  return (
    <Button
      type="link"
      size="small"
      icon={<CopyOutlined />}
      onClick={(e) => {
        e.stopPropagation();
        onCopy();
      }}
    >
      {label ?? '复制'}
    </Button>
  );
}
