import os
import re
import xml.etree.ElementTree as ET
import zlib
import base64
from urllib.parse import unquote, urlparse, parse_qs
import requests

class ConfluenceToMermaidConverter:
    def __init__(self, confluence_url, auth_token):
        self.base_url = f"{urlparse(confluence_url).scheme}://{urlparse(confluence_url).netloc}"
        self.headers = {"Authorization": f"Bearer {auth_token}", "Accept": "application/json"}
        self.page_id = self._extract_page_id(confluence_url)

    def _extract_page_id(self, url):
        parsed = urlparse(url)
        if "pageId=" in url:
            return parse_qs(parsed.query)['pageId'][0]
        match = re.search(r'/pages/(\d+)/', url)
        if match:
            return match.group(1)
        raise ValueError("无法解析 Confluence Page ID，请检查 URL 格式。")

    def get_page_content(self):
        """拉取页面 Storage Format (XHTML) 结构"""
        api_url = f"{self.base_url}/rest/api/content/{self.page_id}?expand=body.storage,children.attachment"
        res = requests.get(api_url, headers=self.headers)
        res.raise_for_status()
        return res.json()

    def decode_drawio_xml(self, raw_xml_str):
        """解包并解压缩 draw.io XML 数据 (处理 base64/zlib 编码)"""
        try:
            root = ET.fromstring(raw_xml_str)
            # 找到 diagram 节点
            diagram = root.find('.//diagram')
            if diagram is not None and diagram.text:
                compressed_data = base64.b64decode(diagram.text)
                # Raw inflate (-wbits)
                decompressed = zlib.decompress(compressed_data, -15)
                xml_text = unquote(decompressed.decode('utf-8'))
                return ET.fromstring(xml_text)
            return root
        except Exception:
            # 如果是明文 XML 则直接解析
            return ET.fromstring(raw_xml_str)

    def parse_drawio_to_mermaid(self, xml_root):
        """【零信息丢失核心】将 draw.io XML 映射为 Mermaid Flowchart"""
        nodes = {}
        edges = []
        subgraphs = {}  # parent_id -> list of child_ids
        styles = {}
        clicks = {}

        for cell in xml_root.findall('.//mxCell'):
            cell_id = cell.attrib.get('id')
            value = cell.attrib.get('value', '')
            parent = cell.attrib.get('parent')
            vertex = cell.attrib.get('vertex')
            edge = cell.attrib.get('edge')
            source = cell.attrib.get('source')
            target = cell.attrib.get('target')
            style = cell.attrib.get('style', '')

            # 清理 HTML 标签，保留换行与链接
            clean_value = re.sub(r'<br\s*/?>', '\\n', value)
            clean_value = re.sub(r'<[^>]+>', '', clean_value).strip()

            # 提取超链接
            link_match = re.search(r'href="([^"]+)"', value)
            if link_match:
                clicks[cell_id] = link_match.group(1)

            # 提取背景色与边框色
            fill_match = re.search(r'fillColor=(#[\da-fA-F]+)', style)
            stroke_match = re.search(r'strokeColor=(#[\da-fA-F]+)', style)
            if fill_match or stroke_match:
                style_str = ""
                if fill_match: style_str += f"fill:{fill_match.group(1)},"
                if stroke_match: style_str += f"stroke:{stroke_match.group(1)},"
                styles[cell_id] = style_str.rstrip(',')

            # 节点处理
            if vertex == '1':
                if parent and parent not in ['0', '1']:
                    subgraphs.setdefault(parent, []).append(cell_id)
                nodes[cell_id] = clean_value if clean_value else f"Node_{cell_id}"

            # 连线处理
            elif edge == '1' and source and target:
                label = f"|\"{clean_value}\"|" if clean_value else ""
                edges.append((source, target, label))

        # 构建 Mermaid 组装串
        mermaid_lines = ["flowchart TD"]

        # 1. 渲染子图容器 (subgraphs)
        written_nodes = set()
        for group_id, child_ids in subgraphs.items():
            group_name = nodes.get(group_id, f"Group_{group_id}")
            mermaid_lines.append(f"    subgraph {group_id}[\"{group_name}\"]")
            for cid in child_ids:
                if cid in nodes:
                    mermaid_lines.append(f"        {cid}[\"{nodes[cid]}\"]")
                    written_nodes.add(cid)
            mermaid_lines.append("    end")

        # 2. 渲染独立节点
        for nid, nval in nodes.items():
            if nid not in written_nodes and nid not in subgraphs:
                mermaid_lines.append(f"    {nid}[\"{nval}\"]")

        # 3. 渲染连线 (保留关系)
        for src, tgt, label in edges:
            mermaid_lines.append(f"    {src} -->{label} {tgt}")

        # 4. 渲染样式与点击事件 (保留颜色与超链接)
        for sid, sval in styles.items():
            if sid in nodes:
                mermaid_lines.append(f"    style {sid} {sval}")
        for cid, url in clicks.items():
            if cid in nodes:
                mermaid_lines.append(f"    click {cid} \"{url}\" _blank")

        return "\n".join(mermaid_lines)

    def process(self):
        page_data = self.get_page_content()
        storage_body = page_data['body']['storage']['value']

        mermaid_outputs = []

        # 匹配页面中的 draw.io 宏数据 (ac:structured-macro name="drawio")
        drawio_matches = re.findall(r'<ac:structured-macro[^>]*ac:name="drawio"[^>]*>([\s\S]*?)</ac:structured-macro>', storage_body)
        
        for idx, macro_xml in enumerate(drawio_matches):
            # 提取 draw.io 的 xml 内容属性
            xml_param = re.search(r'<ac:plain-text-body><!\[CDATA\[([\s\S]*?)\]\]></ac:plain-text-body>', macro_xml)
            if xml_param:
                raw_drawio_xml = xml_param.group(1)
                parsed_xml = self.decode_drawio_xml(raw_drawio_xml)
                mermaid_code = self.parse_drawio_to_mermaid(parsed_xml)
                mermaid_outputs.append(f"%% --- Draw.io Diagram #{idx+1} ---\n{mermaid_code}")

        final_mermaid = "\n\n".join(mermaid_outputs)
        
        # 保存为 .mmd 文件
        output_filename = f"confluence_page_{self.page_id}.mmd"
        with open(output_filename, "w", encoding="utf-8") as f:
            f.write(final_mermaid)

        return final_mermaid, output_filename

# --- Skill 执行入口 ---
def run_skill(page_url, auth_token):
    converter = ConfluenceToMermaidConverter(page_url, auth_token)
    mermaid_code, file_path = converter.process()
    return {
        "mermaid_code": mermaid_code,
        "file_path": file_path
    }