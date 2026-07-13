import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const output = join(import.meta.dirname, '..', '.dev-state', 'fixtures');
mkdirSync(output, { recursive: true });

const files = new Map([
  ['说明文本.txt', 'MyNAS 本地读写验证\r\n中文文件名与 UTF-8 内容正常。\r\n'],
  ['示例代码.ts', 'export const mynas = "本地代码预览正常";\n'],
  ['文档.pdf', '%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n'],
  ['Word文档.docx', 'MyNAS office icon fixture'],
  ['Excel表格.xlsx', 'MyNAS office icon fixture'],
  ['PowerPoint演示.pptx', 'MyNAS office icon fixture'],
  ['压缩文件.zip', 'MyNAS archive icon fixture'],
  ['RAR压缩.rar', 'MyNAS archive icon fixture'],
  ['7z压缩.7z', 'MyNAS archive icon fixture'],
  ['归档.tar', 'MyNAS archive icon fixture'],
  ['压缩数据.gz', 'MyNAS archive icon fixture'],
  ['磁盘镜像.iso', 'MyNAS disk image fixture'],
  ['字体文件.ttf', 'MyNAS font fixture'],
  ['可执行文件.exe', 'MyNAS executable fixture'],
  ['未知类型.mynas-test', 'MyNAS unknown fixture'],
  ['视频文件.mp4', 'MyNAS video icon fixture'],
]);
for (const [name, data] of files) writeFileSync(join(output, name), data);

writeFileSync(join(output, '图片.png'), Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64'));

const samples = 800;
const wav = Buffer.alloc(44 + samples * 2);
wav.write('RIFF', 0); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8);
wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
wav.writeUInt32LE(8000, 24); wav.writeUInt32LE(16000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
wav.write('data', 36); wav.writeUInt32LE(samples * 2, 40);
for (let i = 0; i < samples; i++) wav.writeInt16LE(Math.round(Math.sin(i / 8) * 4000), 44 + i * 2);
writeFileSync(join(output, '音频.wav'), wav);

console.log(output);
