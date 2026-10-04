/**
 * Multi-platform link parsing (ported from the SaveAny reference:
 * DouyinVideoService / XMediaService / TikTokVideoService / InstagramMediaService,
 * direct channels only — the XHS pipeline stays in core/XhsNoteParser).
 */
import { http } from '@kit.NetworkKit';
import { ParseResult, ParseStatus, Platform, WorkType, MediaItem } from '../model/SaveModels';
import { DouyinResolverBridge } from './DouyinResolver';

const IOS_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1';

/** 桌面 Chrome UA（快手 GraphQL / B站 playurl / 抖音 web detail 等 PC web 接口用；v1.28.1 升 131）。 */
const CHROME_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/**
 * 海外平台代理桥：设置页「代理」（host:port）+「代理下载」开关 →
 * X / IG / TikTok 解析与媒体下载走该 HTTP 代理（ohos usingProxy）。
 * 小红书走国内 CDN，不经过此代理（TransferEngine 不接线）。
 * AppContainer.init 与设置变更时调用 NetProxy.apply 同步。
 */
export class NetProxy {
  static host: string = '';
  static port: number = 0;

  static apply(proxyText: string, enabled: boolean): void {
    const t = proxyText.trim();
    const m = t.match(/^(?:https?:\/\/)?([A-Za-z0-9.\-]+):(\d{2,5})\/?$/);
    if (enabled && t.length > 0 && m !== null) {
      NetProxy.host = m[1] as string;
      NetProxy.port = parseInt(m[2] as string, 10);
    } else {
      NetProxy.host = '';
      NetProxy.port = 0;
    }
  }

  /** usingProxy 取值：未启用时返回 true（跟随系统默认），启用时返回指定代理。 */
  static option(): boolean | http.HttpProxy {
    if (NetProxy.host.length > 0 && NetProxy.port > 0) {
      const proxy: http.HttpProxy = { host: NetProxy.host, port: NetProxy.port, exclusionList: [] };
      return proxy;
    }
    return true;
  }
}

interface TitleAuthor {
  title: string;
  author: string;
}

/** getFollow 的返回：正文 + 最终 URL + 收集到的 Cookie。 */
class HttpPage {
  text: string = '';
  finalUrl: string = '';
  cookies: string = '';
}

/** 镜像直链分类结果：kind = 'video' | 'image' | 'cover'。 */
class MirrorMedia {
  kind: string = '';
  url: string = '';
}

class Http {
  static async getText(url: string, ua: string, referer: string, connectTimeout: number = 15000): Promise<string> {
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      const header: Record<string, string> = {
        'User-Agent': ua.length > 0 ? ua : IOS_UA,
        'Accept': '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: NetProxy.option(),
        connectTimeout: connectTimeout,
        readTimeout: 20000
      };
      const resp = await req.request(url, opt);
      req.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 400) {
        const data = resp.result as string;
        return data ? data : '';
      }
      return '';
    } catch (e) {
      if (req !== null) {
        req.destroy();
      }
      return '';
    }
  }

  /** GET，携带额外请求头（i.instagram App API 等）。 */
  static async getWithHeaders(url: string, ua: string, referer: string,
    extra: Record<string, string>, connectTimeout: number = 15000): Promise<string> {
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      const header: Record<string, string> = {
        'User-Agent': ua.length > 0 ? ua : IOS_UA,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9'
      };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const ks = Object.keys(extra);
      for (const k of ks) {
        header[k] = extra[k];
      }
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: NetProxy.option(),
        connectTimeout: connectTimeout,
        readTimeout: 20000
      };
      const resp = await req.request(url, opt);
      req.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 400) {
        const data = resp.result as string;
        return data ? data : '';
      }
      return '';
    } catch (e) {
      if (req !== null) {
        req.destroy();
      }
      return '';
    }
  }

  /** GET，手动跟随跳转，返回正文与最终 URL（短链解析需要）。
   *  cookie 参数非空时作为请求 Cookie 头发送；sendCookies 时收集每跳 Set-Cookie。 */
  static async getFollow(url: string, ua: string, referer: string, maxHops: number,
    forceSystem: boolean = false, cookie: string = '', sendCookies: boolean = false): Promise<HttpPage> {
    const out = new HttpPage();
    const collected: string[] = [];
    let current: string = url;
    for (let hop = 0; hop < maxHops; hop++) {
      let req: http.HttpRequest | null = null;
      let code = 0;
      let body = '';
      let location = '';
      try {
        req = http.createHttp();
        const header: Record<string, string> = {
          'User-Agent': ua.length > 0 ? ua : IOS_UA,
          'Accept': '*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9'
        };
        if (referer.length > 0) {
          header['Referer'] = referer;
        }
        if (cookie.length > 0) {
          header['Cookie'] = cookie;
        }
        const opt: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: header,
          expectDataType: http.HttpDataType.STRING,
          usingCache: false,
          // forceSystem：强制走系统网络（不走应用代理），供国内可达的镜像站使用
          usingProxy: forceSystem ? true : NetProxy.option(),
          connectTimeout: 15000,
          readTimeout: 20000
        };
        const resp = await req.request(current, opt);
        req.destroy();
        req = null;
        code = resp.responseCode;
        body = typeof resp.result === 'string' ? (resp.result as string) : '';
        const raw: Object | undefined = resp.header;
        if (raw !== undefined && raw !== null) {
          const h = raw as Record<string, Object>;
          for (const k of Object.keys(h)) {
            const lk = k.toLowerCase();
            if (lk === 'location') {
              const v = h[k];
              location = typeof v === 'string' ? v : '';
            } else if (sendCookies && (lk === 'set-cookie' || lk === 'setcookie')) {
              // 多条 Set-Cookie 在 ohos http 里可能是 string 或 Array，统一归一化
              const v = h[k];
              if (typeof v === 'string') {
                collected.push(v);
              } else if (Array.isArray(v)) {
                for (const item of v as Array<Object>) {
                  collected.push(String(item));
                }
              }
            }
          }
        }
      } catch (e) {
        if (req !== null) {
          req.destroy();
        }
        break;
      }
      if (code >= 300 && code < 400 && location.length > 0) {
        current = location.indexOf('http') === 0 ? location : Http.absolute(current, location);
        continue;
      }
      out.text = code >= 200 && code < 400 ? body : '';
      out.finalUrl = current;
      out.cookies = Http.mergeCookies(collected);
      return out;
    }
    return out;
  }

  /**
   * 两段式握手 GET（抖音分享页等 JS 挑战壳场景）：首请求收集 Set-Cookie
   * （ttwid/__ac_nonce），带 Cookie 重放一次拿真实页面。
   */
  static async getWithCookieFlow(url: string, ua: string, referer: string, maxHops: number,
    challengeMarker: string = 'jsvmprt'): Promise<HttpPage> {
    const first = await Http.getFollow(url, ua, referer, maxHops, false, '', true);
    if (first.text.length === 0 || first.cookies.length === 0) {
      return first;
    }
    // 已是真实页面（无挑战壳）就不浪费第二次请求
    if (first.text.indexOf(challengeMarker) < 0 && first.text.indexOf('_ROUTER_DATA') >= 0) {
      return first;
    }
    return await Http.getFollow(url, ua, referer, maxHops, false, first.cookies, true);
  }

  /** 归一化收集到的 Set-Cookie：取每个 cookie 的 name=value，按 name 去重。 */
  static mergeCookies(raw: string[]): string {
    const map = new Map<string, string>();
    for (const line of raw) {
      // 一段 Set-Cookie 可能内含多个（逗号分隔，如 Expires 的逗号需排除）
      const parts = line.split(/,(?=[A-Za-z0-9_]+=)/);
      for (const part of parts) {
        const seg = part.trim();
        const eq = seg.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const name = seg.slice(0, eq).trim();
        let value = seg.slice(eq + 1);
        const semi = value.indexOf(';');
        if (semi >= 0) {
          value = value.slice(0, semi);
        }
        if (name.length > 0 && /^[A-Za-z0-9_$]+$/.test(name)) {
          map.set(name, value);
        }
      }
    }
    let out = '';
    map.forEach((value: string, key: string): void => {
      out += (out.length > 0 ? '; ' : '') + key + '=' + value;
    });
    return out;
  }

  /** POST 表单/JSON（Instagram graphql 等接口），返回 2xx/3xx 正文，否则空串。
   *  forceSystem：强制走系统网络不走应用代理（国内接口用）。 */
  static async postForm(url: string, body: string, headers: Record<string, string>, ua: string,
    referer: string, forceSystem: boolean = false): Promise<string> {
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      const header: Record<string, string> = {
        'User-Agent': ua.length > 0 ? ua : IOS_UA,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9'
      };
      const ks = Object.keys(headers);
      for (const k of ks) {
        header[k] = headers[k];
      }
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const opt: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: forceSystem ? true : NetProxy.option(),
        connectTimeout: 15000,
        readTimeout: 20000
      };
      const resp = await req.request(url, opt);
      req.destroy();
      if (resp.responseCode >= 200 && resp.responseCode < 400) {
        const data = resp.result as string;
        return data ? data : '';
      }
      return '';
    } catch (e) {
      if (req !== null) {
        req.destroy();
      }
      return '';
    }
  }

  static absolute(base: string, relative: string): string {
    const m = base.match(/^https?:\/\/[^/]+/i);
    const origin = m !== null ? m[0] : '';
    if (relative.indexOf('/') === 0) {
      return origin + relative;
    }
    const slash = base.lastIndexOf('/');
    return (slash > 8 ? base.substring(0, slash + 1) : origin + '/') + relative;
  }

  static decodeHtml(text: string): string {
    return text
      .replace(/\\u002F/g, '/')
      .replace(/\\u0026/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&#x27;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&');
  }

  /** 手写 base64/url-safe base64 解码（结果按 ASCII 处理，供 efg 参数嗅探用）。 */
  static base64Decode(input: string): string {
    const alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const safe = input.replace(/-/g, '+').replace(/_/g, '/').replace(/%3D/gi, '=');
    let acc = 0;
    let bits = 0;
    let out = '';
    for (const ch of safe) {
      if (ch === '=') {
        break;
      }
      const idx = alpha.indexOf(ch);
      if (idx < 0) {
        continue;
      }
      acc = ((acc << 6) | idx) & 0xFFFFFF;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((acc >> bits) & 0xFF);
      }
    }
    return out;
  }

  static num(v: Object | undefined | null): number {
    return typeof v === 'number' ? v as number : 0;
  }

  /** Balanced {..} extraction starting at `start` (string/escape aware). */
  static extractBalancedJson(text: string, start: number): string {
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let i = start; i < text.length && i < start + 3000000; i++) {
      const ch = text.charAt(i);
      if (esc) {
        esc = false;
        continue;
      }
      if (ch === '\\') {
        esc = true;
        continue;
      }
      if (ch === '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) {
        continue;
      }
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return text.substring(start, i + 1);
        }
      }
    }
    return '';
  }
}

/** 抖音（直连 _ROUTER_DATA 通道）。 */
export class DouyinService {
  static isDouyinUrl(url: string): boolean {
    return url.indexOf('douyin.com') >= 0 || url.indexOf('iesdouyin.com') >= 0;
  }

  static shareUrl(url: string): string {
    const m = url.match(/(?:iesdouyin|m\.douyin)\.com\/share\/(video|note|slides)\/(\d+)/) ||
      url.match(/douyin\.com\/(video|note|slides)\/(\d+)/);
    if (m !== null) {
      return `https://www.iesdouyin.com/share/${m[1]}/${m[2]}`;
    }
    if (url.indexOf('v.douyin.com') >= 0) {
      return url;
    }
    return url;
  }

  static postType(url: string): string {
    if (url.indexOf('/slides/') >= 0) {
      return 'slides';
    }
    if (url.indexOf('/note/') >= 0) {
      return 'note';
    }
    return 'video';
  }

  static awemeId(url: string): string {
    const m = url.match(/(?:video|note|slides)\/(\d{6,})/) ||
      url.match(/modal_id=(\d{6,})/) || url.match(/aweme_id=(\d{6,})/);
    return m !== null ? m[1] : '';
  }

  /** 页面里出现 _ROUTER_DATA 且有作品数据才返回，否则继续试下一个通道。 */
  static tryRouterData(html: string, sourceUrl: string): ParseResult | null {
    const start = html.indexOf('window._ROUTER_DATA');
    if (start < 0) {
      return null;
    }
    const brace = html.indexOf('{', start);
    if (brace < 0) {
      return null;
    }
    const jsonText = Http.extractBalancedJson(html, brace);
    if (jsonText.length === 0) {
      return null;
    }
    const r = DouyinService.mapRouterData(jsonText, sourceUrl);
    return r.status === ParseStatus.OK ? r : null;
  }

  /** 旧版 iteminfo / web detail API 返回 item_list。 */
  static fromItemList(text: string, sourceUrl: string): ParseResult | null {
    try {
      const root = JSON.parse(text) as Record<string, Object>;
      const list = Array.isArray(root['item_list']) ? root['item_list'] as Array<Object> : [];
      if (list.length === 0) {
        return null;
      }
      const result = new ParseResult();
      result.platform = Platform.DOUYIN;
      result.sourceUrl = sourceUrl;
      const built = DouyinService.buildFromAweme(list[0] as Record<string, Object>, result);
      return built.status === ParseStatus.OK ? built : null;
    } catch (e) {
      return null;
    }
  }

  /** web detail API（aweme/v1/web/aweme/detail）返回 aweme_detail 单对象。 */
  static fromAwemeDetail(text: string, sourceUrl: string): ParseResult | null {
    try {
      const root = JSON.parse(text) as Record<string, Object>;
      const detail = root['aweme_detail'] as Record<string, Object>;
      if (detail === null || detail === undefined) {
        return null;
      }
      const result = new ParseResult();
      result.platform = Platform.DOUYIN;
      result.sourceUrl = sourceUrl;
      const built = DouyinService.buildFromAweme(detail, result);
      return built.status === ParseStatus.OK ? built : null;
    } catch (e) {
      return null;
    }
  }

  /** 兜底：直接从页面源码抓 CDN 直链（抖音不再内联作品数据时的唯一办法）。 */
  static fromHtmlUrls(html: string, sourceUrl: string): ParseResult | null {
    const flat = html.replace(/\\\//g, '/');
    const result = new ParseResult();
    result.platform = Platform.DOUYIN;
    result.sourceUrl = sourceUrl;
    const videos: string[] = [];
    const images: string[] = [];
    const vids = flat.match(/https?:\/\/[^"'\s\\]+?\.(?:mp4|mov)[^"'\s\\]*/gi);
    if (vids !== null) {
      for (const u of vids) {
        if (DouyinService.isDouyinCdn(u) && videos.indexOf(u) < 0) {
          videos.push(u);
        }
      }
    }
    const imgs = flat.match(/https?:\/\/[^"'\s\\]+?(?:douyinpic|byteimg|p\d+-aio)[^"'\s\\]*?\.(?:jpeg|jpg|png|webp)[^"'\s\\]*/gi);
    if (imgs !== null) {
      for (const u of imgs) {
        if (images.indexOf(u) < 0) {
          images.push(u);
        }
      }
    }
    if (videos.length > 0) {
      const best = DouyinService.pickBestVideo(videos);
      const mi = new MediaItem();
      mi.url = best.length > 0 ? best : videos[0];
      mi.type = WorkType.VIDEO;
      result.mediaItems.push(mi);
      result.workType = WorkType.VIDEO;
    } else if (images.length > 0) {
      let count = 0;
      for (const u of images) {
        if (count >= 20) {
          break;
        }
        const mi = new MediaItem();
        mi.url = u;
        mi.type = WorkType.IMAGES;
        result.mediaItems.push(mi);
        count++;
      }
      result.workType = WorkType.IMAGES;
      result.coverUrl = images[0];
    } else {
      return null;
    }
    result.status = ParseStatus.OK;
    result.title = InstagramService.metaContent(flat, 'og:title');
    result.author = InstagramService.metaContent(flat, 'og:author');
    return result;
  }

  static isDouyinCdn(url: string): boolean {
    return url.indexOf('douyinvod') >= 0 || url.indexOf('byteimg') >= 0 ||
      url.indexOf('p3-aio') >= 0 || url.indexOf('p6-aio') >= 0 ||
      url.indexOf('p9-aio') >= 0 || url.indexOf('amemv') >= 0 ||
      url.indexOf('douyinstatic') >= 0 || url.indexOf('iesdouyin') >= 0;
  }

  /**
   * 多通道解析：短链跳转 → 分享页 _ROUTER_DATA → 官网页 → 旧 API →
   * 页面直链兜底。抖音当前把作品数据改为异步加载，直连常拿不到，
   * 全部失败时标记 webFallback，由 UI 引导使用网页内核提取。
   */
  static async parse(url: string): Promise<ParseResult> {
    const failed = DouyinService.fail(url);
    const entry = DouyinService.shareUrl(url);
    // 通道〇（v1.26.7）：两段式握手——首请求收集 ttwid/__ac_nonce，带 Cookie
    // 重放。2026 年分享页对裸请求回挑战壳，数据改为客户端异步加载，
    // 带上握手 Cookie 至少能拿到完整 shell（数据回归时此通道立即生效）。
    const page = await Http.getWithCookieFlow(entry, IOS_UA, 'https://www.douyin.com/', 6);
    const sourceUrl = page.finalUrl.length > 0 ? page.finalUrl : (entry.length > 0 ? entry : url);
    failed.sourceUrl = sourceUrl;
    const id = DouyinService.awemeId(sourceUrl.length > 0 ? sourceUrl : url);
    // v1.29.0（datatool.vip 参考古后收敛）：静态通道全部短路。
    // 2026-10-04 实测——iesdouyin 分享页整页 jsvmp 挑战壳（_$jsvmprt，
    // _ROUTER_DATA 内联数据已消失）、www.douyin.com 桌面页对裸请求同样
    // 挑战、web detail API 200 空 body（需 msToken/a_bogus 签名）、
    // iteminfo 旧接口死透。datatool.vip 等在线解析站的共性是服务端
    // 浏览器渲染池——对应本应用的 ArkWeb 同构方案（页面自己过挑战 +
    // 页面 JS 自己算签名调 detail API，钩子只拦截响应）。此前的静态
    // 四通道每单解析浪费 4 次请求与数秒超时，直接砍掉；握手仅用于
    // v.douyin.com 短链跟跳拿 aweme id。数据统一走下方 WebView 通道。
    // 通道四（兜底，v1.26.5，SaveAny 同款）：隐藏 WebView 加载分享页，
    // 多轮注入抓 _ROUTER_DATA + DOM——直连被 JS 挑战壳/风控拦住时，
    // WebView 内核执行挑战脚本跳到真实页面后仍能拿到完整作品数据。
    // v1.26.6：有 aweme id 时直接加载 share 长链（少一次短链跳转），
    // resolve reject（busy/未挂载）不再中断整个解析。
    let webUrl = entry.length > 0 ? entry : url;
    if (id.length > 0) {
      // v1.28.0（videdown 同款）：加载 www.douyin.com 桌面页（Chrome UA），
      // 页面自身 JS 调 detail API、WebView 钩子拦截响应——分享页风控最重，
      // 桌面页是浏览器正常用户入口，是最稳的取数页面。
      webUrl = `https://www.douyin.com/${DouyinService.postType(sourceUrl.length > 0 ? sourceUrl : url)}/${id}`;
    }
    let viaWeb = '';
    try {
      viaWeb = await DouyinResolverBridge.resolve(webUrl);
    } catch (e) {
      viaWeb = '';
    }
    if (viaWeb.length > 0 && viaWeb !== '{}') {
      const r = DouyinService.fromResolverJson(viaWeb, sourceUrl);
      if (r !== null) {
        return r;
      }
    }
    failed.message = '抖音解析失败（平台风控或需登录），可改用「网页提取」';
    failed.webFallback = true;
    return failed;
  }

  /** WebView 注入脚本返回的 JSON → ParseResult。v1.28.0 起注入可能交付
   *  detail API 原始 JSON（aweme_detail/item_list 结构）或旧版精简结构，
   *  依次尝试后兜底。
   *  v1.28.1 关键修复：ArkWeb runJavaScript 返回的是脚本求值结果的
   *  JSON 序列化——脚本返回字符串时结果带外层引号与内部转义
   *  （"{\"desc\":...}"）。直接 JSON.parse 得到的是 string 而非对象，
   *  三条解析路径全部落空（数据其实抓到了）——这就是 v1.28.0 WebView
   *  通道"注入成功仍解析失败"的根因。此处先归一化再分发。 */
  static fromResolverJson(rawText: string, sourceUrl: string): ParseResult | null {
    let jsonText = rawText.trim();
    if (jsonText.length > 1 && jsonText.charAt(0) === '"' && jsonText.charAt(jsonText.length - 1) === '"') {
      try {
        const decoded = JSON.parse(jsonText) as string;
        if (typeof decoded === 'string' && decoded.trim().charAt(0) === '{') {
          jsonText = decoded.trim();
        }
      } catch (e) {
        // 外层引号但非法 JSON：保持原样，让后续路径报错
      }
    }
    // 防御：结果仍可能是二次编码的字符串（多层引号），循环解开
    let guard = 0;
    while (jsonText.length > 1 && jsonText.charAt(0) === '"' && jsonText.charAt(jsonText.length - 1) === '"' && guard < 3) {
      try {
        const decoded = JSON.parse(jsonText) as string;
        if (typeof decoded !== 'string' || decoded.trim().charAt(0) !== '{') {
          break;
        }
        jsonText = decoded.trim();
        guard++;
      } catch (e) {
        break;
      }
    }
    const api1 = DouyinService.fromAwemeDetail(jsonText, sourceUrl);
    if (api1 !== null) {
      return api1;
    }
    const api2 = DouyinService.fromItemList(jsonText, sourceUrl);
    if (api2 !== null) {
      return api2;
    }
    try {
      const root = JSON.parse(jsonText) as Record<string, Object>;
      const item: Record<string, Object> = {};
      item['desc'] = root['desc'] as Object;
      const author = root['author'] as Record<string, Object>;
      const authorOut: Record<string, Object> = {};
      if (author !== null && author !== undefined) {
        authorOut['nickname'] = author['nickname'] as Object;
      }
      item['author'] = authorOut as Object;
      item['images'] = root['images'] as Object;
      item['music'] = root['music'] as Object;
      item['video'] = root['video'] as Object;
      const result = new ParseResult();
      result.platform = Platform.DOUYIN;
      result.sourceUrl = sourceUrl;
      const built = DouyinService.buildFromAweme(item, result);
      return built.status === ParseStatus.OK ? built : null;
    } catch (e) {
      return null;
    }
  }

  static mapRouterData(jsonText: string, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.DOUYIN;
    result.sourceUrl = sourceUrl;
    const postType = DouyinService.postType(sourceUrl);
    result.workType = postType === 'video' ? WorkType.VIDEO : WorkType.IMAGES;
    try {
      const root = JSON.parse(jsonText) as Record<string, Object>;
      const loader = root['loaderData'] as Record<string, Object>;
      let item: Record<string, Object> | null = null;
      if (loader !== null && loader !== undefined) {
        const keys = Object.keys(loader);
        for (const k of keys) {
          if (k.indexOf('/page') < 0) {
            continue;
          }
          const pageData = loader[k] as Record<string, Object>;
          const videoInfo = pageData['videoInfoRes'] as Record<string, Object>;
          const slidesInfo = pageData['slidesInfoRes'] as Record<string, Object>;
          if (videoInfo !== null && videoInfo !== undefined && Array.isArray(videoInfo['item_list'])) {
            const list = videoInfo['item_list'] as Array<Object>;
            if (list.length > 0) {
              item = list[0] as Record<string, Object>;
              break;
            }
          }
          if (slidesInfo !== null && slidesInfo !== undefined && Array.isArray(slidesInfo['aweme_details'])) {
            const list = slidesInfo['aweme_details'] as Array<Object>;
            if (list.length > 0) {
              item = list[0] as Record<string, Object>;
              break;
            }
          }
        }
      }
      if (item === null) {
        result.status = ParseStatus.PARSE_FAILED;
        result.message = '没有解析到作品数据，请确认作品仍可公开访问';
        return result;
      }
      return DouyinService.buildFromAweme(item, result);
    } catch (e) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '没有解析到作品数据，请确认作品仍可公开访问';
      return result;
    }
  }

  static buildFromAweme(item: Record<string, Object>, result: ParseResult): ParseResult {
    if (typeof item['desc'] === 'string') {
      result.title = (item['desc'] as string).trim();
    }
    const author = item['author'] as Record<string, Object>;
    if (author !== null && author !== undefined && typeof author['nickname'] === 'string') {
      result.author = (author['nickname'] as string).trim();
    }
    const images = item['images'];
    if (Array.isArray(images)) {
      for (const img of images as Array<Object>) {
        const rec = img as Record<string, Object>;
        const urls = Array.isArray(rec['url_list']) ? rec['url_list'] as Array<Object> :
          (Array.isArray(rec['download_url_list']) ? rec['download_url_list'] as Array<Object> : []);
        for (const u of urls) {
          if (typeof u === 'string' && (u as string).indexOf('http') === 0) {
            const mi = new MediaItem();
            mi.url = u as string;
            mi.type = WorkType.IMAGES;
            mi.width = Http.num(rec['width']);
            mi.height = Http.num(rec['height']);
            result.mediaItems.push(mi);
            break;
          }
        }
      }
      if (result.mediaItems.length > 0) {
        result.workType = WorkType.IMAGES;
      }
    }
    const video = item['video'] as Record<string, Object>;
    if (video !== null && video !== undefined && result.mediaItems.length === 0) {
      result.mediaWidth = Http.num(video['width']);
      result.mediaHeight = Http.num(video['height']);
      const cover = video['cover'] as Record<string, Object>;
      if (cover !== null && cover !== undefined && Array.isArray(cover['url_list'])) {
        for (const u of cover['url_list'] as Array<Object>) {
          if (typeof u === 'string' && (u as string).indexOf('http') === 0) {
            result.coverUrl = u as string;
            break;
          }
        }
      }
      const playAddr = video['play_addr'] as Record<string, Object>;
      if (playAddr !== null && playAddr !== undefined) {
        const candidates: string[] = [];
        // bit_rate 多码率列表（videdown 同源数据）：优先收 h264 高清直链
        if (Array.isArray(video['bit_rate'])) {
          for (const br of video['bit_rate'] as Array<Object>) {
            const rec = br as Record<string, Object>;
            const brAddr = rec['play_addr'] as Record<string, Object>;
            if (brAddr !== null && brAddr !== undefined && Array.isArray(brAddr['url_list'])) {
              for (const u of brAddr['url_list'] as Array<Object>) {
                if (typeof u === 'string') {
                  candidates.push(u as string);
                }
              }
            }
          }
        }
        const uri = typeof playAddr['uri'] === 'string' ? playAddr['uri'] as string : '';
        if (uri.length > 0) {
          candidates.push('https://www.iesdouyin.com/aweme/v1/play/?line=0&video_id=' +
            encodeURIComponent(uri) + '&downgrade_264=1');
          candidates.push('https://www.iesdouyin.com/aweme/v1/play/?video_id=' + uri + '&ratio=1080p&line=0');
        }
        if (Array.isArray(playAddr['url_list'])) {
          for (const u of playAddr['url_list'] as Array<Object>) {
            if (typeof u === 'string') {
              candidates.push(u as string);
            }
          }
        }
        const best = DouyinService.pickBestVideo(candidates);
        if (best.length > 0) {
          const mi = new MediaItem();
          mi.url = best;
          mi.type = WorkType.VIDEO;
          mi.width = result.mediaWidth;
          mi.height = result.mediaHeight;
          result.mediaItems.push(mi);
          result.workType = WorkType.VIDEO;
        }
      }
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '没有解析到图文或视频内容，请确认作品公开且链接有效';
      return result;
    }
    result.status = ParseStatus.OK;
    return result;
  }

  static pickBestVideo(candidates: string[]): string {
    let best = '';
    let bestScore = -1000;
    for (const c of candidates) {
      let score = 0;
      if (c.indexOf('downgrade_264=1') >= 0) {
        score += 100;
      }
      if (c.indexOf('codec_type=0') >= 0 || /[?&]cs=0(?:&|$)/.test(c)) {
        score += 60;
      }
      if (c.indexOf('h264') >= 0) {
        score += 40;
      }
      if (c.indexOf('/aweme/v1/play') >= 0) {
        score += 10;
      }
      if (c.indexOf('playwm') >= 0) {
        score -= 20;
      }
      if (c.indexOf('douyinvod.com') >= 0) {
        score += 40;
      }
      if (c.indexOf('/video/tos/') >= 0) {
        score += 30;
      }
      if (c.indexOf('h265') >= 0 || c.indexOf('hevc') >= 0 || /[?&]cs=2(?:&|$)/.test(c)) {
        score -= 40;
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  static fail(url: string): ParseResult {
    const p = new ParseResult();
    p.platform = Platform.DOUYIN;
    p.sourceUrl = url;
    p.status = ParseStatus.PARSE_FAILED;
    p.message = '没有解析到图文或视频内容，请确认作品公开且链接有效';
    return p;
  }
}

/** X（Twitter）：fxtwitter API 主通道 + og meta 兜底。 */
export class XService {
  static isXUrl(url: string): boolean {
    return url.indexOf('x.com/') >= 0 || url.indexOf('twitter.com/') >= 0 || url.indexOf('t.co/') >= 0;
  }

  static statusId(url: string): string {
    const m = url.match(/\/status(?:es)?\/(\d+)/);
    return m !== null ? m[1] : '';
  }

  static async parse(url: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.X;
    failed.sourceUrl = url;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = '没有解析到图文或视频内容，请确认作品公开且链接有效';
    // t.co 短链：先跟到最终 x.com 地址再取 status id。
    // ohos http 默认自动跟跳（finalUrl 仍是原 t.co 地址），因此若正文里
    // 出现 x.com 目标地址，直接从 HTML 提取（国内网络 t.co 本身不可达，
    // 这里主要是配合代理环境的兜底）。
    let target = url;
    if (target.indexOf('t.co/') >= 0) {
      const page = await Http.getFollow(target, IOS_UA, '', 4);
      if (page.finalUrl.length > 0 && page.finalUrl.indexOf('t.co/') < 0) {
        target = page.finalUrl;
        failed.sourceUrl = target;
      } else if (page.text.length > 0) {
        const inner = page.text.match(/https?:\/\/(?:x|twitter)\.com\/[A-Za-z0-9_]+\/status\/(\d+)/);
        if (inner !== null) {
          target = inner[0];
          failed.sourceUrl = target;
        }
      }
    }
    const id = XService.statusId(target);
    if (id.length === 0) {
      failed.message = '不是可识别的 X 作品链接';
      return failed;
    }
    // 通道 1：fxtwitter API（Cloudflare，国内直连可达——实测主通道）
    try {
      const body = await Http.getText(`https://api.fxtwitter.com/status/${id}`, 'XHSDownloader/1.0', '', 8000);
      if (body.length > 0) {
        const mapped = XService.mapFxTwitter(body, url);
        if (mapped.status === ParseStatus.OK) {
          return mapped;
        }
      }
    } catch (e) {
      // fallthrough
    }
    // 通道 2：vxtwitter API（国内通常不可达，快速失败 6s）
    try {
      const body = await Http.getText(`https://api.vxtwitter.com/i/status/${id}`, IOS_UA, '', 6000);
      if (body.length > 0) {
        const mapped = XService.mapVxTwitter(body, url);
        if (mapped.status === ParseStatus.OK) {
          return mapped;
        }
      }
    } catch (e) {
      // fallthrough
    }
    // 通道 3（SaveAny 同款兜底）：x.com 页面 og meta + 最高码率 mp4（需代理）
    try {
      const page = await Http.getText(`https://x.com/i/status/${id}`, IOS_UA, 'https://x.com/', 6000);
      if (page.length > 0) {
        const mapped = XService.mapOgMeta(page, url);
        if (mapped.status === ParseStatus.OK) {
          return mapped;
        }
      }
    } catch (e) {
      // fallthrough
    }
    // 全部失败：fxtwitter 不可达或作品无媒体。媒体下载还需代理（twimg 被墙）。
    failed.message = 'X 解析失败：镜像通道不可达或作品无媒体。媒体下载需在「设置 → 网络」配置代理（如 127.0.0.1:7890）后开启代理下载，或改用「网页提取」';
    failed.webFallback = true;
    return failed;
  }

  /** og:title 形如「文本 (@user) on X」→ 拆出正文与作者。 */
  static splitOgTitle(rawTitle: string): TitleAuthor {
    const out: TitleAuthor = { title: rawTitle, author: '' };
    const m = rawTitle.match(/^([\s\S]*?)\s+\(@([^)]+)\)\s+on X$/);
    if (m !== null) {
      out.title = (m[1] as string).trim();
      out.author = (m[2] as string).trim();
    }
    return out;
  }

  /** bitrate 最高码率的 mp4 直链（页面嵌入的 variant 列表）。 */
  static highestBitrateVideo(html: string): string {
    const re = /bitrate:(\d+),content_type:"video\/mp4",url:"((?:\\.|[^"\\])*)"/g;
    let best = '';
    let bestBitrate = -1;
    let m: RegExpExecArray | null = re.exec(html);
    while (m !== null) {
      const bitrate = parseInt(m[1] as string);
      if (!isNaN(bitrate) && bitrate > bestBitrate) {
        bestBitrate = bitrate;
        best = m[2] as string;
      }
      m = re.exec(html);
    }
    return best;
  }

  /** x.com og meta 兜底：og:image 为 poster / 直图，variant 里挑最高码率 mp4。 */
  static mapOgMeta(html: string, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.X;
    result.sourceUrl = sourceUrl;
    const title = Http.decodeHtml(XService.metaContent(html, 'og:title'));
    const split = XService.splitOgTitle(title);
    if (split.title.length > 0) {
      result.title = split.title;
    }
    if (split.author.length > 0) {
      result.author = split.author;
    }
    const image = Http.decodeHtml(XService.metaContent(html, 'og:image'));
    const video = XService.highestBitrateVideo(html);
    if (video.length > 0) {
      const mi = new MediaItem();
      mi.type = WorkType.VIDEO;
      mi.url = video.replace(/\\\//g, '/').replace(/\\u0026/g, '&');
      if (image.length > 0) {
        mi.posterUrl = image;
      }
      result.mediaItems.push(mi);
      result.workType = WorkType.VIDEO;
      result.coverUrl = mi.posterUrl;
    } else if (image.length > 0 && image.indexOf('/photo/') < 0) {
      const mi = new MediaItem();
      mi.type = WorkType.IMAGES;
      mi.url = image;
      result.mediaItems.push(mi);
      result.workType = WorkType.IMAGES;
      result.coverUrl = mi.url;
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      return result;
    }
    result.status = ParseStatus.OK;
    return result;
  }

  static metaContent(html: string, prop: string): string {
    const safe = prop.replace(':', '\\:');
    const re = new RegExp('<meta[^>]+(?:property|name)="' + safe + '"[^>]+content="([^"]*)"', 'i');
    const alt = new RegExp('<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="' + safe + '"', 'i');
    const m = re.exec(html) !== null ? re.exec(html) : alt.exec(html);
    return m !== null ? m[1] : '';
  }

  /** vxtwitter 响应映射：mediaURLs 数组。 */
  static mapVxTwitter(body: string, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.X;
    result.sourceUrl = sourceUrl;
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      if (typeof root['text'] === 'string') {
        result.title = root['text'] as string;
      }
      if (typeof root['user_name'] === 'string') {
        result.author = root['user_name'] as string;
      }
      const urls = root['mediaURLs'];
      if (Array.isArray(urls)) {
        for (const raw of urls as Array<Object>) {
          if (typeof raw !== 'string') {
            continue;
          }
          const u = raw as string;
          const mi = new MediaItem();
          mi.url = u;
          const isVideo = u.indexOf('.mp4') >= 0 || u.indexOf('/video/') >= 0;
          mi.type = isVideo ? WorkType.VIDEO : WorkType.IMAGES;
          result.mediaItems.push(mi);
        }
      }
      if (result.mediaItems.length === 0) {
        result.status = ParseStatus.PARSE_FAILED;
        return result;
      }
      result.workType = result.mediaItems[0].type;
      result.status = ParseStatus.OK;
      return result;
    } catch (e) {
      result.status = ParseStatus.PARSE_FAILED;
      return result;
    }
  }

  static mapFxTwitter(body: string, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.X;
    result.sourceUrl = sourceUrl;
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      const tweet = root['tweet'] as Record<string, Object>;
      if (tweet === null || tweet === undefined) {
        result.status = ParseStatus.PARSE_FAILED;
        return result;
      }
      if (typeof tweet['text'] === 'string') {
        result.title = tweet['text'] as string;
      }
      const author = tweet['author'] as Record<string, Object>;
      if (author !== null && author !== undefined && typeof author['name'] === 'string') {
        result.author = author['name'] as string;
      }
      const media = tweet['media'] as Record<string, Object>;
      if (media !== null && media !== undefined) {
        if (Array.isArray(media['videos'])) {
          for (const v of media['videos'] as Array<Object>) {
            const rec = v as Record<string, Object>;
            if (typeof rec['url'] === 'string') {
              const mi = new MediaItem();
              mi.type = WorkType.VIDEO;
              mi.url = rec['url'] as string;
              if (typeof rec['thumbnail_url'] === 'string') {
                mi.posterUrl = rec['thumbnail_url'] as string;
              }
              mi.width = Http.num(rec['width']);
              mi.height = Http.num(rec['height']);
              result.mediaItems.push(mi);
              break;
            }
          }
        }
        if (Array.isArray(media['photos'])) {
          for (const p of media['photos'] as Array<Object>) {
            const rec = p as Record<string, Object>;
            if (typeof rec['url'] === 'string') {
              const mi = new MediaItem();
              mi.type = WorkType.IMAGES;
              mi.url = rec['url'] as string;
              mi.width = Http.num(rec['width']);
              mi.height = Http.num(rec['height']);
              result.mediaItems.push(mi);
            }
          }
        }
      }
      if (result.mediaItems.length === 0) {
        result.status = ParseStatus.PARSE_FAILED;
        return result;
      }
      result.workType = result.mediaItems[0].type;
      result.coverUrl = result.mediaItems[0].type === WorkType.VIDEO ?
        result.mediaItems[0].posterUrl : result.mediaItems[0].url;
      result.status = ParseStatus.OK;
      return result;
    } catch (e) {
      result.status = ParseStatus.PARSE_FAILED;
      return result;
    }
  }
}

/** TikTok：__UNIVERSAL_DATA_FOR_REHYDRATION__ / SIGI_STATE 通道。 */
export class TikTokService {
  static isTikTokUrl(url: string): boolean {
    return url.indexOf('tiktok.com') >= 0;
  }

  static videoId(url: string): string {
    const m = url.match(/\/video\/(\d+)/);
    return m !== null ? m[1] : '';
  }

  static async parse(url: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.TIKTOK;
    failed.sourceUrl = url;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = '没有解析到图文或视频内容，请确认作品公开且链接有效';
    const id = TikTokService.videoId(url);
    const pageUrl = id.length > 0 ? `https://www.tiktok.com/@user/video/${id}` : url;
    const html = await Http.getText(pageUrl, IOS_UA, 'https://www.tiktok.com/');
    if (html.length === 0) {
      return failed;
    }
    const uni = TikTokService.scriptJson(html, '__UNIVERSAL_DATA_FOR_REHYDRATION__');
    if (uni.length > 0) {
      const mapped = TikTokService.mapUniversal(uni, url);
      if (mapped.status === ParseStatus.OK) {
        return mapped;
      }
    }
    const sigi = TikTokService.scriptJson(html, 'SIGI_STATE');
    if (sigi.length > 0) {
      const mapped2 = TikTokService.mapSigi(sigi, url, id);
      if (mapped2.status === ParseStatus.OK) {
        return mapped2;
      }
    }
    return failed;
  }

  static scriptJson(html: string, marker: string): string {
    const start = html.indexOf(`id="${marker}"`);
    if (start < 0) {
      return '';
    }
    const brace = html.indexOf('{', start);
    if (brace < 0) {
      return '';
    }
    return Http.extractBalancedJson(html, brace);
  }

  static mapUniversal(jsonText: string, sourceUrl: string): ParseResult {
    try {
      const root = JSON.parse(jsonText) as Record<string, Object>;
      const scope = root['__DEFAULT_SCOPE__'] as Record<string, Object>;
      if (scope === null || scope === undefined) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      const detail = scope['webapp.video-detail'] as Record<string, Object>;
      if (detail === null || detail === undefined) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      const itemInfo = detail['itemInfo'] as Record<string, Object>;
      if (itemInfo === null || itemInfo === undefined) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      const item = itemInfo['itemStruct'] as Record<string, Object>;
      if (item === null || item === undefined) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      return TikTokService.mapItemStruct(item, sourceUrl);
    } catch (e) {
      const empty = new ParseResult();
      empty.status = ParseStatus.PARSE_FAILED;
      return empty;
    }
  }

  static mapSigi(jsonText: string, sourceUrl: string, videoId: string): ParseResult {
    try {
      const root = JSON.parse(jsonText) as Record<string, Object>;
      const modules = root['ItemModule'] as Record<string, Object>;
      if (modules === null || modules === undefined) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      const keys = Object.keys(modules);
      let chosen: Record<string, Object> | null = null;
      for (const k of keys) {
        if (videoId.length === 0 || k === videoId) {
          chosen = modules[k] as Record<string, Object>;
          break;
        }
      }
      if (chosen === null) {
        const empty = new ParseResult();
        empty.status = ParseStatus.PARSE_FAILED;
        return empty;
      }
      return TikTokService.mapItemStruct(chosen, sourceUrl);
    } catch (e) {
      const empty = new ParseResult();
      empty.status = ParseStatus.PARSE_FAILED;
      return empty;
    }
  }

  static mapItemStruct(item: Record<string, Object>, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.TIKTOK;
    result.sourceUrl = sourceUrl;
    if (typeof item['desc'] === 'string') {
      result.title = item['desc'] as string;
    }
    const author = item['author'] as Record<string, Object>;
    if (author !== null && author !== undefined && typeof author['nickname'] === 'string') {
      result.author = author['nickname'] as string;
    }
    const imagePost = item['imagePost'] as Record<string, Object>;
    if (imagePost !== null && imagePost !== undefined && Array.isArray(imagePost['images'])) {
      for (const img of imagePost['images'] as Array<Object>) {
        const rec = img as Record<string, Object>;
        const imageURL = rec['imageURL'] as Record<string, Object>;
        if (imageURL !== null && imageURL !== undefined && Array.isArray(imageURL['urlList'])) {
          for (const u of imageURL['urlList'] as Array<Object>) {
            if (typeof u === 'string' && (u as string).indexOf('http') === 0) {
              const mi = new MediaItem();
              mi.url = u as string;
              mi.type = WorkType.IMAGES;
              result.mediaItems.push(mi);
              break;
            }
          }
        }
      }
    }
    const video = item['video'] as Record<string, Object>;
    if (video !== null && video !== undefined && result.mediaItems.length === 0) {
      const playAddr = typeof video['playAddr'] === 'string' ? video['playAddr'] as string : '';
      if (playAddr.length > 0) {
        const mi = new MediaItem();
        mi.url = playAddr;
        mi.type = WorkType.VIDEO;
        result.mediaItems.push(mi);
        result.workType = WorkType.VIDEO;
      }
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '没有解析到图文或视频内容，请确认作品公开且链接有效';
      return result;
    }
    result.workType = result.mediaItems[0].type;
    result.status = ParseStatus.OK;
    return result;
  }
}

/**
 * Instagram 解析（v1.26.1 多通道）：
 *  - 镜像通道（免代理）：InstaFix 系镜像（kkinstagram 等）bot UA 请求时 302
 *    直出真实媒体直链——国内直连可达，思路同 X 的 fxtwitter 主通道；
 *  - 页面通道：帖子页 HTML xig_polaris_media（scrapfly 2026-09 实测，未登录
 *    payload 嵌在 if_not_gated_logged_out 之下，REST 风格字段）；
 *  - graphql 通道：web /api/graphql（2026-06-29 曾下线，保留兜底）；
 *  - App API 通道：shortcode 本地转 media_id（base64 互转，已与 ig_cache_key
 *    交叉验证）→ i.instagram.com/api/v1/media/{id}/info/（免登录，需代理）；
 *  - embed/captioned 与 og meta 兜底。
 */
export class InstagramService {
  /** graphql 接口要求的桌面 UA。 */
  static readonly DESKTOP_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  /** InstaFix 系镜像的 bot UA：非 bot UA 会被 302 回 instagram.com。 */
  static readonly BOT_UA: string = 'TelegramBot (like Twitterbot)';
  /** i.instagram App API 的客户端 UA 与应用 ID。 */
  static readonly IG_APP_UA: string = 'Instagram 276.0.0.26.103 Android (33/13; 420dpi; 1080x2400; ' +
    'samsung; SM-G991B; o1s; qcom; en_US; 447193818)';
  static readonly IG_APP_ID: string = '936619743392459';
  /** 镜像实例列表（instagramez 已验证被广告劫持，不采用）。
   *  v1.28.1：补裸域变体——www 子域与裸域是两条解析路径，单一实例 504
   *  （2026-10-04 实测 www.kkinstagram.com 全量 504）时不至于全灭。 */
  // v1.26.6 实测：vxinstagram 对所有请求 401（实例已死）、gginstagram 证书坏、
  // ddinstagram 国内直连不可达——公共实例仅剩 kkinstagram 系可用。
  static readonly MIRROR_HOSTS: string[] = ['www.kkinstagram.com', 'kkinstagram.com'];

  static isInstagramUrl(url: string): boolean {
    return url.indexOf('instagram.com') >= 0 || url.indexOf('instagr.am') >= 0;
  }

  static shortcode(url: string): string {
    // 兼容 /reels/（复数，网页版路径）、/p/、/reel/、/tv/
    const m = url.match(/\/(?:p|reel|reels|tv)\/([A-Za-z0-9_-]+)/);
    return m !== null ? m[1] : '';
  }

  static postType(url: string): string {
    if (url.indexOf('/reels/') >= 0) {
      return 'reel';
    }
    const m = url.match(/\/(p|reel|tv)\//);
    return m !== null ? m[1] : 'p';
  }

  /** 从跟跳结果页 HTML 提取 shortcode：canonical 链接 / og:url / JSON 字段。 */
  static shortcodeFromHtml(html: string): string {
    const m = html.match(/instagram\.com\/(?:p|reel|tv)\/([A-Za-z0-9_-]+)/) ||
      html.match(/"shortcode"\s*:\s*"([A-Za-z0-9_-]+)"/) ||
      html.match(/"short_code"\s*:\s*"([A-Za-z0-9_-]+)"/);
    return m !== null ? m[1] : '';
  }

  /**
   * 通道〇b（2026 主通道，scrapfly 2026-09 实测）：帖子页 HTML 解析。
   * 单帖 graphql 已于 2026-06-29 被 IG 下线；公开帖数据现内嵌在帖子页
   * <script type="application/json" data-sjs> 的 xig_polaris_media 里，
   * 未登录请求时真实 payload 嵌在 if_not_gated_logged_out 之下。
   * 字段为 REST 风格：image_versions2.candidates / video_versions / carousel_media。
   * v1.26.1：桌面 UA 无数据时用移动 UA 变体重试（两种 UA 下页面 payload 不同）。
   */
  static async pageHtmlParse(code: string, postType: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.INSTAGRAM;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = '页面通道无数据';
    const pageUrl = `https://www.instagram.com/${postType}/${code}/`;
    let gotPage = false;
    const uas: string[] = [InstagramService.DESKTOP_UA, IOS_UA];
    for (const ua of uas) {
      const html = await Http.getText(pageUrl, ua, '');
      if (html.length === 0) {
        continue;
      }
      gotPage = true;
      const r = InstagramService.extractFromPageHtml(html, pageUrl);
      if (r !== null) {
        return r;
      }
    }
    if (!gotPage) {
      failed.message = 'Instagram 帖子页获取失败';
      return failed;
    }
    failed.message = '页面未包含帖子数据（可能被登录墙拦截）';
    failed.webFallback = true;
    return failed;
  }

  /** 帖子页 HTML 统一提取：xig_polaris_media → xdt_shortcode_media → og meta。 */
  static extractFromPageHtml(html: string, pageUrl: string): ParseResult | null {
    const key = '"xig_polaris_media"';
    let idx = html.indexOf(key);
    if (idx >= 0) {
      return InstagramService.mapPolarisHtml(html, idx, pageUrl);
    }
    // script 内 JSON 可能整体转义（\" 形式），反转义后再找
    const unescaped = html.split('\\"').join('"');
    idx = unescaped.indexOf(key);
    if (idx >= 0) {
      return InstagramService.mapPolarisHtml(unescaped, idx, pageUrl);
    }
    // 同页 graphql 残留形态（"xdt_shortcode_media"）—— polaris 缺失时的兜底
    let sx = html.indexOf('"xdt_shortcode_media"');
    let src = html;
    if (sx < 0) {
      sx = unescaped.indexOf('"xdt_shortcode_media"');
      src = unescaped;
    }
    if (sx >= 0) {
      const brace = src.indexOf('{', sx);
      const jsonText = Http.extractBalancedJson(src, brace);
      if (jsonText.length > 0) {
        try {
          const media = JSON.parse(jsonText) as Record<string, Object>;
          const mapped = InstagramService.mapShortcode(media, pageUrl);
          if (mapped.status === ParseStatus.OK && mapped.mediaItems.length > 0) {
            return mapped;
          }
        } catch (e) {
          // 落到 og meta
        }
      }
    }
    const og = InstagramService.ogMeta(html, pageUrl);
    if (og.status === ParseStatus.OK && og.mediaItems.length > 0) {
      return og;
    }
    return null;
  }

  /** 从 html 的 key 位置提取 xig_polaris_media 值对象并映射。 */
  static mapPolarisHtml(html: string, keyIdx: number, pageUrl: string): ParseResult {
    const brace = html.indexOf('{', keyIdx + '"xig_polaris_media"'.length);
    if (brace < 0) {
      const failed = new ParseResult();
      failed.platform = Platform.INSTAGRAM;
      failed.status = ParseStatus.PARSE_FAILED;
      failed.message = '帖子数据提取失败';
      return failed;
    }
    const jsonText = Http.extractBalancedJson(html, brace);
    if (jsonText.length === 0) {
      const failed = new ParseResult();
      failed.platform = Platform.INSTAGRAM;
      failed.status = ParseStatus.PARSE_FAILED;
      failed.message = '帖子数据提取失败';
      return failed;
    }
    try {
      const media = JSON.parse(jsonText) as Record<string, Object>;
      // 未登录请求：真实 payload 嵌在 if_not_gated_logged_out 之下
      const gated = media['if_not_gated_logged_out'] as Record<string, Object>;
      const target = (gated !== null && gated !== undefined) ? gated : media;
      return InstagramService.mapPolaris(target, pageUrl);
    } catch (e) {
      const failed = new ParseResult();
      failed.platform = Platform.INSTAGRAM;
      failed.status = ParseStatus.PARSE_FAILED;
      failed.message = '帖子数据解析失败';
      failed.webFallback = true;
      return failed;
    }
  }

  /** REST 风格单节点 → 媒体项：photo 用 image_versions2 最大图，video 用 video_versions 最大清晰度。 */
  static polarisNodeToItem(node: Record<string, Object>): MediaItem | null {
    const mi = new MediaItem();
    mi.width = Http.num(node['original_width']);
    mi.height = Http.num(node['original_height']);
    const videos = node['video_versions'];
    if (Array.isArray(videos) && (videos as Array<Object>).length > 0) {
      // 选分辨率最高的视频版本
      let best: Record<string, Object> | null = null;
      let bestW = -1;
      for (const v of videos as Array<Object>) {
        const vo = v as Record<string, Object>;
        const w = Http.num(vo['width']);
        if (w > bestW) {
          bestW = w;
          best = vo;
        }
      }
      if (best !== null && typeof best['url'] === 'string') {
        mi.type = WorkType.VIDEO;
        mi.url = best['url'] as string;
        const imgs = node['image_versions2'] as Record<string, Object>;
        if (imgs !== null && imgs !== undefined) {
          const cands = imgs['candidates'] as Array<Object>;
          if (Array.isArray(cands) && cands.length > 0) {
            const c0 = cands[0] as Record<string, Object>;
            if (typeof c0['url'] === 'string') {
              mi.posterUrl = c0['url'] as string;
            }
          }
        }
        return mi;
      }
    }
    const imgs2 = node['image_versions2'] as Record<string, Object>;
    if (imgs2 !== null && imgs2 !== undefined) {
      const cands = imgs2['candidates'] as Array<Object>;
      if (Array.isArray(cands) && cands.length > 0) {
        let best: Record<string, Object> | null = null;
        let bestW = -1;
        for (const c of cands as Array<Object>) {
          const co = c as Record<string, Object>;
          const w = Http.num(co['width']);
          if (w > bestW) {
            bestW = w;
            best = co;
          }
        }
        if (best !== null && typeof best['url'] === 'string') {
          mi.type = WorkType.IMAGES;
          mi.url = best['url'] as string;
          return mi;
        }
      }
    }
    return null;
  }

  /** xig_polaris_media（或 if_not_gated_logged_out 解包后）→ ParseResult。 */
  static mapPolaris(media: Record<string, Object>, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.INSTAGRAM;
    result.sourceUrl = sourceUrl;
    result.status = ParseStatus.OK;
    const cap = media['caption'] as Record<string, Object>;
    if (cap !== null && cap !== undefined && typeof cap['text'] === 'string') {
      result.title = cap['text'] as string;
    }
    const user = media['user'] as Record<string, Object>;
    if (user !== null && user !== undefined && typeof user['username'] === 'string') {
      result.author = user['username'] as string;
    }
    // 轮播（media_type 8 / product_type carousel_container）
    const carousel = media['carousel_media'];
    if (Array.isArray(carousel)) {
      for (const c of carousel as Array<Object>) {
        const co = c as Record<string, Object>;
        const mi = InstagramService.polarisNodeToItem(co);
        if (mi !== null) {
          result.mediaItems.push(mi);
        }
      }
    }
    if (result.mediaItems.length === 0) {
      const single = InstagramService.polarisNodeToItem(media);
      if (single !== null) {
        result.mediaItems.push(single);
      }
    }
    if (result.title.length === 0) {
      result.title = 'Instagram';
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '帖子数据中没有媒体直链';
      result.webFallback = true;
    }
    return result;
  }

  /**
   * 镜像通道（v1.26.1 新增，免代理）：InstaFix 系镜像对 bot UA 的请求会
   * 302 直出真实媒体直链（fbcdn/cdninstagram）。实测 /p/{code} 照片直链
   * 可用；视频帖直出的常是封面帧（efg vencode_tag 含 video），此时改试
   * /videos/{code}/1 端点；若镜像只回 HTML（上游原版行为），解析 og:video
   * / og:image 并跟跳其相对路径。全部实例失败返回 null。
   */
  /** v1.28.1：InstaFix oEmbed JSON 端点解析（/p/{code}/json）。 */
  static async mirrorJsonParse(host: string, code: string, sourceUrl: string): Promise<ParseResult | null> {
    const resp = await Http.getFollow(`https://${host}/${InstagramService.shortcodePath(code)}/json`,
      InstagramService.BOT_UA, '', 3, true);
    const raw = resp.text;
    if (raw.length < 20) {
      return null;
    }
    try {
      const root = JSON.parse(raw) as Record<string, Object>;
      const isVideo = root['is_video'] === true;
      const videoUrl = typeof root['video_url'] === 'string' ? root['video_url'] as string : '';
      const images = root['images'];
      const result = new ParseResult();
      result.platform = Platform.INSTAGRAM;
      result.sourceUrl = sourceUrl;
      result.workType = WorkType.VIDEO;
      const username = typeof root['username'] === 'string' ? root['username'] as string : '';
      result.author = username;
      const description = typeof root['description'] === 'string' ? root['description'] as string : '';
      result.title = description.length > 0 ? description : (username.length > 0 ? `Instagram · ${username}` : 'Instagram');
      if (isVideo && videoUrl.length > 0) {
        const mi = new MediaItem();
        mi.url = videoUrl;
        mi.type = WorkType.VIDEO;
        result.mediaItems.push(mi);
      } else if (Array.isArray(images)) {
        for (const img of images as Array<Object>) {
          const u = typeof img === 'string' ? img : String((img as Record<string, Object>)['url'] ?? '');
          if (u.length > 0) {
            const mi2 = new MediaItem();
            mi2.url = u;
            mi2.type = WorkType.IMAGES;
            result.mediaItems.push(mi2);
          }
        }
        result.workType = WorkType.IMAGES;
      }
      if (result.mediaItems.length === 0) {
        return null;
      }
      result.status = ParseStatus.OK;
      return InstagramService.applyNoProxyRelay(result);
    } catch (e) {
      return null;
    }
  }

  /** oEmbed JSON 端点的路径类型： reels 用 /reel/，其余一律 /p/（JSON 端点实测只认这两个前缀）。 */
  static shortcodePath(code: string): string {
    return `p/${code}`;
  }
  static async mirrorParse(code: string, postType: string, sourceUrl: string): Promise<ParseResult | null> {
    for (const host of InstagramService.MIRROR_HOSTS) {
      // v1.28.1 通道：InstaFix oEmbed JSON 端点（/{type}/{code}/json）。
      // 该 handler 与 HTML handler 独立——HTML 504（上游转 IG 超时）时
      // JSON 常仍可用；结构固定：images[] / is_video / video_url。
      const meta = await InstagramService.mirrorJsonParse(host, code, sourceUrl);
      if (meta !== null) {
        return meta;
      }
      const entry = `https://${host}/${postType}/${code}/`;
      // forceSystem：镜像站国内可达，强制系统网络，避免被应用代理拖垮
      const page = await Http.getFollow(entry, InstagramService.BOT_UA, '', 3, true);
      const direct = InstagramService.directMediaFromFollow(page.finalUrl);
      if (direct !== null) {
        if (direct.kind === 'cover') {
          // 视频帖封面帧：试 /videos/ 端点拿 mp4 直链
          const vid = await Http.getFollow(`https://${host}/videos/${code}/1`,
            InstagramService.BOT_UA, '', 3, true);
          const vdirect = InstagramService.directMediaFromFollow(vid.finalUrl);
          if (vdirect !== null && vdirect.kind === 'video') {
            return InstagramService.buildMirrorResult(vdirect.url, direct.url, sourceUrl);
          }
          continue;
        }
        if (direct.kind === 'image') {
          // v1.26.5：轮播展开——img_index 逐张探测（IG 轮播上限 20）。
          // 重定向型实例：302 直出该张直链；HTML 型实例：og:image 指向
          // /images/{code}/{idx} 再跟跳。越界/重复/封面帧/网格图即停，
          // 单图帖第 2 张会原样返回第一张，仅多一次请求。
          const items: MirrorMedia[] = [direct];
          for (let idx = 2; idx <= 20; idx++) {
            const p2 = await Http.getFollow(`https://${host}/${postType}/${code}/?img_index=${idx}`,
              InstagramService.BOT_UA, '', 3, true);
            let d2 = InstagramService.directMediaFromFollow(p2.finalUrl);
            if (d2 === null && p2.text.length > 0) {
              const og2 = InstagramService.metaContent(p2.text, 'og:image');
              if (og2.length > 0 && og2.indexOf('/grid/') < 0) {
                const abs2 = og2.indexOf('/') === 0 ? `https://${host}${og2}` : og2;
                const pg3 = await Http.getFollow(abs2, InstagramService.BOT_UA, '', 3, true);
                d2 = InstagramService.directMediaFromFollow(pg3.finalUrl);
              }
            }
            if (d2 === null || d2.kind !== 'image') {
              break;
            }
            const d2url: string = d2.url;
            if (items.some((it: MirrorMedia): boolean => it.url === d2url)) {
              break;
            }
            items.push(d2);
          }
          return InstagramService.buildMirrorResultMulti(items, sourceUrl);
        }
        // 视频 mp4 直链
        return InstagramService.buildMirrorResult(direct.url, '', sourceUrl);
      }
      if (page.text.length > 0) {
        const r = await InstagramService.mirrorFromHtml(page.text, host, code, sourceUrl, postType);
        if (r !== null) {
          return r;
        }
      }
    }
    return null;
  }

  /** 镜像跟跳结果分类：'video' | 'image' | 'cover'（视频封面帧）| null。 */
  static directMediaFromFollow(finalUrl: string): MirrorMedia | null {
    if (finalUrl.length === 0) {
      return null;
    }
    const lower = finalUrl.toLowerCase();
    const isCdn = lower.indexOf('fbcdn.net') >= 0 || lower.indexOf('cdninstagram.com') >= 0;
    if (!isCdn) {
      return null;
    }
    // v1.26.5：头像直链过滤（profile pic 目录 t51.2885-19 / 150x150 缩略）——
    // 不是帖子照片，误用会导致「只解析到头像」
    if (InstagramService.isProfilePicUrl(finalUrl)) {
      return null;
    }
    if (lower.indexOf('.mp4') >= 0 || lower.indexOf('/o1/v/') >= 0) {
      const m = new MirrorMedia();
      m.kind = 'video';
      m.url = finalUrl;
      return m;
    }
    if (lower.indexOf('.jpg') >= 0 || lower.indexOf('.jpeg') >= 0 || lower.indexOf('.png') >= 0 ||
      lower.indexOf('.webp') >= 0) {
      const m2 = new MirrorMedia();
      if (InstagramService.efgMarksVideo(finalUrl)) {
        // efg 的 vencode_tag 含 video：这是视频封面帧，不是可保存的照片
        m2.kind = 'cover';
      } else {
        m2.kind = 'image';
      }
      m2.url = finalUrl;
      return m2;
    }
    return null;
  }

  /**
   * 头像直链判定（v1.26.6 统一入口）：t51.2885-19 是 IG 头像专用 CDN 目录；
   * /sNNNxNNN/ 是 CDN 缩略尺寸段（头像常见 150x150）。登录墙/主页分享场景
   * 下 og:image 常回落到头像——不过滤就会「解析到头像」。
   */
  static isProfilePicUrl(url: string): boolean {
    const lower = url.toLowerCase();
    if (lower.indexOf('2885-19') >= 0) {
      return true;
    }
    if (lower.indexOf('profile_pic') >= 0) {
      return true;
    }
    const m = lower.match(/\/s(\d{2,4})x\1\//);
    return m !== null && Number(m[1]) <= 320;
  }

  /** efg 参数（base64 的 JSON）解码后是否含 video（视频封面帧标记）。 */
  static efgMarksVideo(url: string): boolean {
    const m = url.match(/[?&]efg=([^&]+)/);
    if (m === null) {
      return false;
    }
    const dec = Http.base64Decode(m[1]);
    return dec.indexOf('video') >= 0;
  }

  /** 上游原版镜像返回 HTML：og:video/og:image 指向 /videos/ /images/ 相对路径，跟跳拿直链。 */
  static async mirrorFromHtml(html: string, host: string, code: string, sourceUrl: string,
    postType: string): Promise<ParseResult | null> {
    const videoMeta = InstagramService.metaContent(html, 'og:video');
    const imageMeta = InstagramService.metaContent(html, 'og:image');
    const resolve = async (meta: string): Promise<MirrorMedia | null> => {
      if (meta.length === 0) {
        return null;
      }
      const abs = meta.indexOf('/') === 0 ? `https://${host}${meta}` : meta;
      const page = await Http.getFollow(abs, InstagramService.BOT_UA, '', 3, true);
      return InstagramService.directMediaFromFollow(page.finalUrl);
    };
    const title = Http.decodeHtml(InstagramService.metaContent(html, 'og:title'));
    if (videoMeta.length > 0) {
      const v = await resolve(videoMeta);
      if (v !== null && v.kind === 'video') {
        let poster = '';
        if (imageMeta.length > 0) {
          const img = await resolve(imageMeta);
          if (img !== null && img.kind === 'image') {
            poster = img.url;
          }
        }
        return InstagramService.buildMirrorResult(v.url, poster, sourceUrl, title);
      }
      return null;
    }
    if (imageMeta.length > 0) {
      if (imageMeta.indexOf('/grid/') >= 0) {
        // v1.26.5：轮播帖——上游多图时 og:image 指向 /grid/ 网格拼图，
        // 改为逐张 img_index 探测展开（og:image → /images/{code}/{idx}）
        const items: MirrorMedia[] = [];
        for (let idx = 1; idx <= 20; idx++) {
          const p2 = await Http.getFollow(`https://${host}/${postType}/${code}/?img_index=${idx}`,
            InstagramService.BOT_UA, '', 3, true);
          const og2 = InstagramService.metaContent(p2.text, 'og:image');
          if (og2.length === 0 || og2.indexOf('/grid/') >= 0) {
            break;
          }
          const abs2 = og2.indexOf('/') === 0 ? `https://${host}${og2}` : og2;
          const pg3 = await Http.getFollow(abs2, InstagramService.BOT_UA, '', 3, true);
          const d3 = InstagramService.directMediaFromFollow(pg3.finalUrl);
          if (d3 === null || d3.kind !== 'image') {
            break;
          }
          const d3url: string = d3.url;
          if (items.some((it: MirrorMedia): boolean => it.url === d3url)) {
            break;
          }
          items.push(d3);
        }
        if (items.length > 0) {
          return InstagramService.buildMirrorResultMulti(items, sourceUrl, title);
        }
        return null;
      }
      const img = await resolve(imageMeta);
      if (img !== null && img.kind === 'image') {
        return InstagramService.buildMirrorResult(img.url, img.url, sourceUrl, title);
      }
    }
    return null;
  }

  /** 镜像结果打包（镜像直出单媒体；视频带封面帧时一并作 poster）。 */
  static buildMirrorResult(url: string, poster: string, sourceUrl: string, title: string = ''): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.INSTAGRAM;
    result.sourceUrl = sourceUrl;
    result.status = ParseStatus.OK;
    result.title = title.length > 0 ? title : 'Instagram';
    const lower = url.toLowerCase();
    const isVideo = lower.indexOf('.mp4') >= 0 || lower.indexOf('/o1/v/') >= 0;
    const mi = new MediaItem();
    mi.url = url;
    mi.type = isVideo ? WorkType.VIDEO : WorkType.IMAGES;
    if (isVideo && poster.length > 0) {
      mi.posterUrl = poster;
    }
    result.mediaItems.push(mi);
    result.workType = mi.type;
    result.coverUrl = isVideo ? poster : url;
    return result;
  }

  /** v1.26.5：镜像轮播展开结果打包（多张图片 / 单张也走这里）。 */
  static buildMirrorResultMulti(items: MirrorMedia[], sourceUrl: string, title: string = ''): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.INSTAGRAM;
    result.sourceUrl = sourceUrl;
    result.status = ParseStatus.OK;
    result.title = title.length > 0 ? title : 'Instagram';
    for (const it of items) {
      const lower = it.url.toLowerCase();
      const isVideo = lower.indexOf('.mp4') >= 0 || lower.indexOf('/o1/v/') >= 0;
      const mi = new MediaItem();
      mi.url = it.url;
      mi.type = isVideo ? WorkType.VIDEO : WorkType.IMAGES;
      result.mediaItems.push(mi);
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '镜像通道没有可用媒体';
      return result;
    }
    result.workType = result.mediaItems[0].type;
    result.coverUrl = result.mediaItems[0].type === WorkType.IMAGES ? result.mediaItems[0].url : '';
    return result;
  }

  /**
   * App API 通道（v1.26.1 新增，免登录，需代理）：
   * shortcode → media_id 纯 base64 互转（InstaFix embed.go mediaidToCode 的
   * 逆变换，已与 fbcdn ig_cache_key 交叉验证）→
   * i.instagram.com/api/v1/media/{id}/info/（公开帖免登录，限流较严）。
   * 返回 REST 字段与 xig_polaris_media 同构，直接复用 mapPolaris。
   */
  static async appApiParse(code: string, sourceUrl: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.INSTAGRAM;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = 'app api 通道无数据';
    const mediaId = InstagramService.mediaIdFromCode(code);
    if (mediaId.length === 0) {
      return failed;
    }
    const headers: Record<string, string> = {
      'X-IG-App-ID': InstagramService.IG_APP_ID,
      'X-Requested-With': 'XMLHttpRequest',
      'X-ASBD-ID': '129477',
      'X-IG-WWW-Claim': '0',
      'Accept': 'application/json',
      'X-CSRFToken': 'missing'
    };
    const resp = await Http.getWithHeaders(`https://i.instagram.com/api/v1/media/${mediaId}/info/`,
      InstagramService.IG_APP_UA, '', headers);
    if (resp.length === 0) {
      return failed;
    }
    try {
      const root = JSON.parse(resp) as Record<string, Object>;
      const items = root['items'];
      if (!Array.isArray(items) || (items as Array<Object>).length === 0) {
        return failed;
      }
      const item = (items as Array<Object>)[0] as Record<string, Object>;
      return InstagramService.mapPolaris(item, sourceUrl);
    } catch (e) {
      return failed;
    }
  }

  /** shortcode → media_id 十进制字符串（64 进制大数转换，避开 BigInt）。 */
  static mediaIdFromCode(code: string): string {
    const alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    let dec = '0';
    for (const ch of code) {
      const idx = alpha.indexOf(ch);
      if (idx < 0) {
        return '';
      }
      dec = InstagramService.bigMulAdd(dec, 64, idx);
    }
    return dec;
  }

  /** 十进制字符串大数：dec * mul + add。 */
  static bigMulAdd(dec: string, mul: number, add: number): string {
    let carry = add;
    let out = '';
    for (let i = dec.length - 1; i >= 0; i--) {
      const v = (dec.charCodeAt(i) - 48) * mul + carry;
      out = String(v % 10) + out;
      carry = Math.floor(v / 10);
    }
    while (carry > 0) {
      out = String(carry % 10) + out;
      carry = Math.floor(carry / 10);
    }
    return out;
  }

  /**
   * v1.28.0 无代理国内中转：fbcdn/cdninstagram 直链国内不可达（实测超时），
   * wsrv.nl（Cloudflare 图片代理，国内直连可用，实测 200 image/jpeg）可完整
   * 中转图片字节流——图片（含轮播/封面）URL 改写为 wsrv 包装，免代理即可
   * 下载与展示。视频 wsrv 无法中转（实测 404），保持原链（需代理下载）。
   * 已配置应用代理时直连原链（原图无第三方重压缩）。
   */
  static proxiedMediaUrl(url: string): string {
    if (url.length === 0 || NetProxy.host.length > 0) {
      return url;
    }
    const lower = url.toLowerCase();
    const isFb = lower.indexOf('fbcdn.net') >= 0 || lower.indexOf('cdninstagram.com') >= 0;
    if (!isFb || lower.indexOf('.mp4') >= 0 || lower.indexOf('/o1/v/') >= 0) {
      return url;
    }
    return 'https://wsrv.nl/?url=' + encodeURIComponent(url) + '&n=-1';
  }

  /** 无代理时对解析成功结果统一做 URL 中转改写（parse() 所有 OK 出口调用）。 */
  static applyNoProxyRelay(result: ParseResult): ParseResult {
    if (NetProxy.host.length > 0) {
      return result;
    }
    for (const mi of result.mediaItems) {
      if (mi.type === WorkType.IMAGES) {
        mi.url = InstagramService.proxiedMediaUrl(mi.url);
      }
      mi.posterUrl = InstagramService.proxiedMediaUrl(mi.posterUrl);
    }
    result.coverUrl = InstagramService.proxiedMediaUrl(result.coverUrl);
    return result;
  }

  static async parse(url: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.INSTAGRAM;
    failed.sourceUrl = url;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = '不是可识别的 Instagram 作品链接';
    // /share/xxx 短链与 instagr.am 先跟到最终 /p|reel|tv/ 地址。
    // 注意 ohos http 默认自动跟跳，finalUrl 仍是原短链地址，因此
    // shortcode 还要从跟跳结果页的 HTML 里提取（canonical / og:url / JSON）。
    let target = url;
    let code = InstagramService.shortcode(target);
    if (code.length === 0) {
      const page = await Http.getFollow(target, IOS_UA, 'https://www.instagram.com/', 4);
      if (page.finalUrl.length > 0) {
        target = page.finalUrl;
        failed.sourceUrl = target;
        code = InstagramService.shortcode(target);
      }
      if (code.length === 0 && page.text.length > 0) {
        code = InstagramService.shortcodeFromHtml(page.text);
      }
    }
    if (code.length === 0) {
      return failed;
    }
    failed.message = '没有解析到 Instagram 作品媒体地址';
    const postType = InstagramService.postType(target);
    const hasProxy = NetProxy.host.length > 0;
    let mirrorTried = false;
    let appApiTried = false;
    const tryMirror = async (): Promise<ParseResult | null> => {
      if (mirrorTried) {
        return null;
      }
      mirrorTried = true;
      return InstagramService.mirrorParse(code, postType, target);
    };
    const tryAppApi = async (): Promise<ParseResult> => {
      if (appApiTried) {
        const miss = new ParseResult();
        miss.platform = Platform.INSTAGRAM;
        miss.status = ParseStatus.PARSE_FAILED;
        miss.message = 'app api 已尝试';
        return miss;
      }
      appApiTried = true;
      return InstagramService.appApiParse(code, target);
    };
    if (!hasProxy) {
      // 免代理：镜像 302 直出真实媒体直链（单图/封面），国内直连可达
      const mirror = await tryMirror();
      if (mirror !== null) {
        return InstagramService.applyNoProxyRelay(mirror);
      }
    } else {
      // 配了代理：App API 优先（v1.26.7 重构）——对数据中心 IP 比
      // 网页通道宽容得多，免登录全量数据（轮播/视频/作者文案）
      const appApi = await tryAppApi();
      if (appApi.status === ParseStatus.OK && appApi.mediaItems.length > 0) {
        return InstagramService.applyNoProxyRelay(appApi);
      }
    }
    // 通道〇b（主）：帖子页 HTML xig_polaris_media（需代理）
    const page = await InstagramService.pageHtmlParse(code, postType);
    if (page.status === ParseStatus.OK && page.mediaItems.length > 0) {
      page.sourceUrl = target;
      return InstagramService.applyNoProxyRelay(page);
    }
    // 通道一（备）：web graphql（2026-06-29 曾下线，IG 可能轮换恢复，保留兜底）
    const gql = await InstagramService.graphqlParse(code);
    if (gql.status === ParseStatus.OK && gql.mediaItems.length > 0) {
      gql.sourceUrl = target;
      return InstagramService.applyNoProxyRelay(gql);
    }
    // 通道一点五：App API（前面没试过时再试）
    const appApi2 = await tryAppApi();
    if (appApi2.status === ParseStatus.OK && appApi2.mediaItems.length > 0) {
      return InstagramService.applyNoProxyRelay(appApi2);
    }
    // 通道二（备）：embed/captioned 页（v1.26.6 提取为方法 + 双 UA 变体）。
    // 注意新版 embed 页的 JSON 已转义塞进 contextJSON（\"shortcode_media\"
    // 形式），需先反转义再配平提取；数据中心 IP 被登录墙时 bot UA 的
    // 简化 embed 常常仍可用。
    const embed = await InstagramService.embedParse(code, postType, target);
    if (embed.status === ParseStatus.OK && embed.mediaItems.length > 0) {
      return InstagramService.applyNoProxyRelay(embed);
    }
    // 通道三：instagram.com 系全败——镜像通道兜底（免代理仍可出照片第一张）
    const mirror2 = await tryMirror();
    if (mirror2 !== null) {
      return InstagramService.applyNoProxyRelay(mirror2);
    }
    if (!hasProxy) {
      failed.message = 'Instagram 解析失败：未配置代理，视频与多图作品无法获取' +
        '（图片经国内中转可下载，视频直链必须代理）。请在「设置 → 网络」配置代理（如 127.0.0.1:7890）并开启「代理下载」后重试';
    } else {
      failed.message = 'Instagram 解析失败（代理通道被登录墙拦截或作品需登录）。' +
        '可尝试更换代理节点后重试，或改用「网页提取」';
    }
    failed.webFallback = true;
    return failed;
  }

  /**
   * web graphql 免登录通道：POST /api/graphql（表单），两个 doc_id 依次尝试
   * （Instagram 会轮换，任一可用即成功）。需代理环境。
   */
  static async graphqlParse(code: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.INSTAGRAM;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = 'graphql 通道无数据';
    const docIds: string[] = ['10015901848480474', '8845758582119845'];
    for (const docId of docIds) {
      const vars = docId === '10015901848480474' ?
        `{"shortcode":"${code}"}` :
        `{"shortcode":"${code}","fetch_tagged_user_count":null,"hoisted_comment_id":null,"hoisted_reply_id":null}`;
      const body = 'variables=' + encodeURIComponent(vars) +
        '&doc_id=' + docId + '&lsd=AVqbxe3J_YA&server_timestamps=true';
      const headers: Record<string, string> = {
        'X-IG-App-ID': '936619743392459',
        'X-FB-LSD': 'AVqbxe3J_YA',
        'X-ASBD-ID': '129477',
        'X-Requested-With': 'XMLHttpRequest',
        'Sec-Fetch-Site': 'same-origin'
      };
      const resp = await Http.postForm('https://www.instagram.com/api/graphql', body, headers,
        InstagramService.DESKTOP_UA, 'https://www.instagram.com/');
      if (resp.length === 0) {
        continue;
      }
      try {
        const root = JSON.parse(resp) as Record<string, Object>;
        const data = root['data'] as Record<string, Object>;
        if (data === null || data === undefined) {
          continue;
        }
        const media = data['xdt_shortcode_media'] as Record<string, Object>;
        if (media === null || media === undefined) {
          continue;
        }
        return InstagramService.mapShortcode(media, '');
      } catch (e) {
        continue;
      }
    }
    return failed;
  }

  /** 单节点 → 媒体项（SaveAny 同款）：视频优先（display_url 作 poster），带尺寸。 */
  static nodeToItem(node: Record<string, Object>): MediaItem | null {
    const mi = new MediaItem();
    const dims = node['dimensions'] as Record<string, Object>;
    if (dims !== null && dims !== undefined) {
      mi.width = Http.num(dims['width']);
      mi.height = Http.num(dims['height']);
    }
    const videoUrl = node['video_url'];
    if (typeof videoUrl === 'string' && (videoUrl as string).length > 0) {
      mi.type = WorkType.VIDEO;
      mi.url = videoUrl as string;
      const display = node['display_url'];
      if (typeof display === 'string') {
        mi.posterUrl = display as string;
      }
      return mi;
    }
    const display = node['display_url'];
    if (typeof display === 'string' && (display as string).length > 0) {
      mi.type = WorkType.IMAGES;
      mi.url = display as string;
      return mi;
    }
    return null;
  }

  static mapShortcode(media: Record<string, Object>, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.INSTAGRAM;
    result.sourceUrl = sourceUrl;
    const captionNode = media['edge_media_to_caption'] as Record<string, Object>;
    if (captionNode !== null && captionNode !== undefined && Array.isArray(captionNode['edges'])) {
      const edges = captionNode['edges'] as Array<Object>;
      if (edges.length > 0) {
        const node = (edges[0] as Record<string, Object>)['node'] as Record<string, Object>;
        if (node !== null && node !== undefined && typeof node['text'] === 'string') {
          result.title = node['text'] as string;
        }
      }
    }
    const owner = media['owner'] as Record<string, Object>;
    if (owner !== null && owner !== undefined && typeof owner['username'] === 'string') {
      result.author = owner['username'] as string;
    }
    const dims = media['dimensions'] as Record<string, Object>;
    if (dims !== null && dims !== undefined) {
      result.mediaWidth = Http.num(dims['width']);
      result.mediaHeight = Http.num(dims['height']);
    }
    // 多图 sidecar
    const sidecar = media['edge_sidecar_to_children'] as Record<string, Object>;
    if (sidecar !== null && sidecar !== undefined && Array.isArray(sidecar['edges'])) {
      for (const edge of sidecar['edges'] as Array<Object>) {
        const node = (edge as Record<string, Object>)['node'] as Record<string, Object>;
        if (node === null || node === undefined) {
          continue;
        }
        const mi = InstagramService.nodeToItem(node);
        if (mi !== null) {
          result.mediaItems.push(mi);
        }
      }
    }
    // 单图 / 单视频
    if (result.mediaItems.length === 0) {
      const single = InstagramService.nodeToItem(media);
      if (single !== null) {
        result.mediaItems.push(single);
      }
    }
    if (result.title.length === 0) {
      result.title = 'Instagram';
    }
    if (result.mediaItems.length === 0) {
      result.status = ParseStatus.PARSE_FAILED;
      result.message = '没有解析到 Instagram 作品媒体地址';
      return result;
    }
    result.workType = result.mediaItems[0].type;
    result.coverUrl = result.mediaItems[0].type === WorkType.VIDEO ?
      result.mediaItems[0].posterUrl : result.mediaItems[0].url;
    result.status = ParseStatus.OK;
    return result;
  }

  /**
   * embed/captioned 通道（v1.26.6 提取为方法 + 双 UA）：
   * shortcode_media（未转义/转义 contextJSON）→ og meta（已过滤头像）。
   * 数据中心 IP 打开帖子页被登录墙时，bot UA 的简化 embed 常常仍可用。
   */
  static async embedParse(code: string, postType: string, sourceUrl: string): Promise<ParseResult> {
    const failed = new ParseResult();
    failed.platform = Platform.INSTAGRAM;
    failed.status = ParseStatus.PARSE_FAILED;
    failed.message = 'embed 通道无数据';
    const embedUrl = `https://www.instagram.com/${postType}/${code}/embed/captioned/`;
    const uas: string[] = [IOS_UA, InstagramService.BOT_UA];
    for (const ua of uas) {
      const html = await Http.getText(embedUrl, ua, 'https://www.instagram.com/');
      if (html.length === 0) {
        continue;
      }
      let start = html.indexOf('"shortcode_media"');
      let src = html;
      if (start < 0) {
        const unescaped = html.split('\\"').join('"');
        start = unescaped.indexOf('"shortcode_media"');
        src = unescaped;
      }
      if (start >= 0) {
        const brace = src.indexOf('{', start);
        const jsonText = Http.extractBalancedJson(src, brace);
        if (jsonText.length > 0) {
          try {
            const media = JSON.parse(jsonText) as Record<string, Object>;
            const mapped = InstagramService.mapShortcode(media, sourceUrl);
            if (mapped.status === ParseStatus.OK && mapped.mediaItems.length > 0) {
              return mapped;
            }
          } catch (e) {
            // 落到 og meta
          }
        }
      }
      const og = InstagramService.ogMeta(html, sourceUrl);
      if (og.status === ParseStatus.OK && og.mediaItems.length > 0) {
        return og;
      }
    }
    return failed;
  }

  static ogMeta(html: string, sourceUrl: string): ParseResult {
    const result = new ParseResult();
    result.platform = Platform.INSTAGRAM;
    result.sourceUrl = sourceUrl;
    const rawImage = InstagramService.metaContent(html, 'og:image');
    const video = InstagramService.metaContent(html, 'og:video');
    const title = InstagramService.metaContent(html, 'og:title');
    const desc = InstagramService.metaContent(html, 'og:description');
    // v1.26.6：登录墙/主页分享时 og:image 常是作者头像——过滤掉，
    // 视为无数据让后续通道（embed/appapi/镜像）继续，而不是错误保存头像。
    const image: string =
      (rawImage.length > 0 && !InstagramService.isProfilePicUrl(Http.decodeHtml(rawImage))) ? rawImage : '';
    if (title.length > 0) {
      result.title = Http.decodeHtml(title);
    } else if (desc.length > 0) {
      result.title = Http.decodeHtml(desc);
    } else {
      result.title = 'Instagram';
    }
    if (video.length > 0) {
      const mi = new MediaItem();
      mi.type = WorkType.VIDEO;
      mi.url = Http.decodeHtml(video);
      if (image.length > 0) {
        mi.posterUrl = Http.decodeHtml(image);
      }
      result.mediaItems.push(mi);
      result.workType = WorkType.VIDEO;
      result.coverUrl = mi.posterUrl;
    } else if (image.length > 0) {
      const mi = new MediaItem();
      mi.url = Http.decodeHtml(image);
      mi.type = WorkType.IMAGES;
      result.mediaItems.push(mi);
      result.workType = WorkType.IMAGES;
      result.coverUrl = mi.url;
    }
    if (result.mediaItems.length > 0) {
      result.status = ParseStatus.OK;
    }
    return result;
  }

  static metaContent(html: string, prop: string): string {
    const safe = prop.replace(':', '\\:');
    const re = new RegExp('<meta[^>]+(?:property|name)="' + safe + '"[^>]+content="([^"]*)"', 'i');
    const alt = new RegExp('<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="' + safe + '"', 'i');
    const m = re.exec(html) !== null ? re.exec(html) : alt.exec(html);
    return m !== null ? m[1] : '';
  }
}

/**
 * 快手（v1.27.0，移植自 videdown）：GraphQL visionVideoDetail 主通道，免登录。
 *  - photoId：/short-video/xxx、/fw/photo/xxx 或 photoId= 参数；
 *  - 短链：v.kuaishou.com / /f/xxx 经 getFollow 跟随重定向后提取；
 *  - GraphQL：先访问 www.kuaishou.com 首页种 Cookie（kpf/kpn/did），
 *    POST www.kuaishou.com/graphql 查询 photo（caption/封面/时长/photoUrl/
 *    manifest 多码率），选最高清晰度 representation 兜底 photoUrl；
 *  - 直链下载实测免 Referer（206 video/mp4），封面直链可直接展示。
 */
export class KuaishouService {
  static isKuaishouUrl(url: string): boolean {
    return url.indexOf('kuaishou.com') >= 0 || url.indexOf('chenzhongtech.com') >= 0;
  }

  static photoId(url: string): string {
    const m = url.match(/\/short-video\/([0-9A-Za-z]+)/) ||
      url.match(/\/fw\/photo\/([0-9A-Za-z]+)/) ||
      url.match(/photoId=([0-9A-Za-z]+)/) ||
      url.match(/\/photo\/([0-9A-Za-z]+)/);
    return m !== null ? m[1] : '';
  }

  static isShortLink(url: string): boolean {
    return url.indexOf('v.kuaishou.com') >= 0 || /\/f\/[0-9A-Za-z]+/.test(url);
  }

  static fail(url: string, msg: string): ParseResult {
    const p = new ParseResult();
    p.platform = Platform.KUAISHOU;
    p.sourceUrl = url;
    p.status = ParseStatus.PARSE_FAILED;
    p.message = msg;
    return p;
  }

  static async parse(url: string): Promise<ParseResult> {
    const target = url.indexOf('http') === 0 ? url : 'https://' + url;
    // 1) 短链跟随重定向拿 photoId（顺带收集跳转 Cookie）
    let cookies = '';
    let pid = KuaishouService.photoId(target);
    if (pid.length === 0 || KuaishouService.isShortLink(target)) {
      const page = await Http.getFollow(target, CHROME_UA, 'https://www.kuaishou.com/', 5,
        true, '', true);
      cookies = page.cookies;
      const finalUrl = page.finalUrl.length > 0 ? page.finalUrl : target;
      pid = KuaishouService.photoId(finalUrl);
      if (pid.length === 0 && page.text.length > 0) {
        const m = page.text.match(/"photoId"\s*:\s*"([0-9A-Za-z]+)"/) ||
          page.text.match(/"photo_id"\s*:\s*"?([0-9A-Za-z]+)"?/);
        pid = m !== null ? m[1] : '';
      }
      if (pid.length === 0) {
        return KuaishouService.fail(url, '未识别到快手作品编号，请确认是视频分享链接');
      }
    }
    // 2) 首页握手种 Cookie（GraphQL 需要 kpf/clientid/kpn/did）
    if (cookies.length === 0) {
      const home = await Http.getFollow('https://www.kuaishou.com/', CHROME_UA, '', 2,
        true, '', true);
      cookies = home.cookies;
    }
    // 3) GraphQL 查询
    const gql = '{"operationName":"VisionVideoDetail","variables":{"photoId":"' + pid +
      '"},"query":"query VisionVideoDetail($photoId: String!) { visionVideoDetail(photoId: ' +
      '$photoId) { status photo { id duration caption coverUrl photoUrl photoH265Url ' +
      'manifest { adaptationSet { representation { id url width height avgBitrate } } } } } }"}';
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    };
    if (cookies.length > 0) {
      headers['Cookie'] = cookies;
    }
    const text = await Http.postForm('https://www.kuaishou.com/graphql', gql, headers,
      CHROME_UA, 'https://www.kuaishou.com/', true);
    if (text.length === 0) {
      return KuaishouService.fail(url, '快手接口请求失败（网络受限），请稍后重试');
    }
    try {
      const root = JSON.parse(text) as Record<string, Object>;
      const data = root['data'] as Record<string, Object>;
      const vvd = data !== null && data !== undefined ?
        data['visionVideoDetail'] as Record<string, Object> : null;
      const photo = vvd !== null && vvd !== undefined ?
        vvd['photo'] as Record<string, Object> : null;
      if (photo === null || photo === undefined) {
        return KuaishouService.fail(url, '快手作品不存在或已删除');
      }
      const title = typeof photo['caption'] === 'string' ?
        (photo['caption'] as string).trim() : '';
      const coverUrl = typeof photo['coverUrl'] === 'string' ? photo['coverUrl'] as string : '';
      // 候选直链：manifest 最高清晰度 + photoUrl + H265 兜底
      const candidates: string[] = [];
      let bestH = -1;
      let bestUrl = '';
      const manifest = photo['manifest'] as Record<string, Object>;
      if (manifest !== null && manifest !== undefined && Array.isArray(manifest['adaptationSet'])) {
        for (const set of manifest['adaptationSet'] as Array<Object>) {
          const rec = set as Record<string, Object>;
          if (!Array.isArray(rec['representation'])) {
            continue;
          }
          for (const rep of rec['representation'] as Array<Object>) {
            const r = rep as Record<string, Object>;
            const u = typeof r['url'] === 'string' ? r['url'] as string : '';
            const h = Http.num(r['height']);
            if (u.length > 0 && h > bestH) {
              bestH = h;
              bestUrl = u;
            }
          }
        }
      }
      if (bestUrl.length > 0) {
        candidates.push(bestUrl);
      }
      if (typeof photo['photoUrl'] === 'string' && (photo['photoUrl'] as string).length > 0) {
        candidates.push(photo['photoUrl'] as string);
      }
      if (typeof photo['photoH265Url'] === 'string' && (photo['photoH265Url'] as string).length > 0) {
        candidates.push(photo['photoH265Url'] as string);
      }
      if (candidates.length === 0) {
        return KuaishouService.fail(url, '未解析到快手视频直链（作品可能仅登录可见）');
      }
      const result = new ParseResult();
      result.platform = Platform.KUAISHOU;
      result.sourceUrl = target;
      result.status = ParseStatus.OK;
      result.noteId = typeof photo['id'] === 'string' ? photo['id'] as string : pid;
      result.title = title.length > 0 ? title : '快手视频';
      result.workType = WorkType.VIDEO;
      result.coverUrl = coverUrl;
      const mi = new MediaItem();
      mi.url = candidates[0];
      mi.type = WorkType.VIDEO;
      result.mediaItems.push(mi);
      return result;
    } catch (e) {
      return KuaishouService.fail(url, '快手解析失败（接口返回异常）');
    }
  }
}

/** 平台识别 + 分发。 */
/**
 * B站（v1.24.0）：公开 API 免登录通道。
 *  - 视频：api.bilibili.com/x/web-interface/view（标题/封面/cid）
 *          + x/player/playurl?platform=html5（durl 合成 mp4 直链）；
 *  - 短链：b23.tv 经 getFollow 跟随重定向后从页面提取 BV 号；
 *  - 图文：/opus/ /read/ 专栏页正则提取 hdslb 图片。
 * 媒体下载需 Referer: https://www.bilibili.com/（MultiDownloader.refererFor 已配置）。
 */
export class BilibiliService {
  static isBilibiliUrl(url: string): boolean {
    return url.indexOf('bilibili.com') >= 0 || url.indexOf('b23.tv') >= 0;
  }

  /** 从 URL 或页面 HTML 提取 BV/av 号。 */
  static bvid(url: string, html: string = ''): string {
    const m = url.match(/BV[0-9A-Za-z]{10}/);
    if (m !== null) {
      return m[0];
    }
    if (html.length > 0) {
      const m2 = html.match(/BV[0-9A-Za-z]{10}/);
      if (m2 !== null) {
        return m2[0];
      }
    }
    const av = url.match(/\/video\/av(\d+)/);
    return av !== null ? 'av' + av[1] : '';
  }

  static isArticleUrl(url: string): boolean {
    return url.indexOf('/opus/') >= 0 || url.indexOf('read/cv') >= 0;
  }

  static failed(url: string, msg: string, webFallback: boolean = false): ParseResult {
    const r = new ParseResult();
    r.platform = Platform.BILIBILI;
    r.sourceUrl = url;
    r.status = ParseStatus.PARSE_FAILED;
    r.message = msg;
    r.webFallback = webFallback;
    return r;
  }

  /** 图文/专栏：抓页面正则提取 hdslb 图片。 */
  static async parseArticle(url: string): Promise<ParseResult> {
    const target = url.indexOf('http') === 0 ? url : 'https://' + url;
    const html = await Http.getText(target, IOS_UA, 'https://www.bilibili.com/');
    if (html.length === 0) {
      return BilibiliService.failed(url, 'B站页面获取失败（网络受限），可在「设置 → 网络」配置代理后重试', true);
    }
    const regex = /https:\/\/i\d\.hdslb\.com\/bfs\/[^"'\\\s)]+\.(?:jpg|jpeg|png|webp|gif)/gi;
    const seen: string[] = [];
    let m: RegExpExecArray | null = regex.exec(html);
    while (m !== null) {
      if (seen.indexOf(m[0]) < 0) {
        seen.push(m[0]);
      }
      m = regex.exec(html);
    }
    if (seen.length === 0) {
      return BilibiliService.failed(url, '未解析到 B站图文图片', true);
    }
    const result = new ParseResult();
    result.platform = Platform.BILIBILI;
    result.sourceUrl = target;
    result.status = ParseStatus.OK;
    result.workType = WorkType.IMAGES;
    result.title = 'B站图文';
    result.coverUrl = seen[0];
    for (const img of seen) {
      const mi = new MediaItem();
      mi.url = img;
      mi.type = WorkType.IMAGES;
      result.mediaItems.push(mi);
    }
    return result;
  }

  static async parse(url: string): Promise<ParseResult> {
    if (BilibiliService.isArticleUrl(url)) {
      return BilibiliService.parseArticle(url);
    }
    const target = url.indexOf('http') === 0 ? url : 'https://' + url;
    let bvid = BilibiliService.bvid(target);
    let html = '';
    // b23.tv 短链 / 带中文分享文案：跟随重定向拉页面提取 BV
    if (bvid.length === 0) {
      const page = await Http.getFollow(target, IOS_UA, 'https://www.bilibili.com/', 4);
      html = page.text;
      // 跟随重定向后拿到最终地址，优先从最终地址提取 BV
      if (page.finalUrl.length > 0) {
        bvid = BilibiliService.bvid(page.finalUrl);
      }
      if (bvid.length === 0) {
        bvid = BilibiliService.bvid(target, html);
      }
      if (html.length === 0) {
        return BilibiliService.failed(url, 'B站页面获取失败（网络受限），可在「设置 → 网络」配置代理后重试', true);
      }
    }
    if (bvid.length === 0) {
      return BilibiliService.failed(url, '未识别到 B站视频编号（BV/av）', true);
    }
    // 视频信息
    const isAv = bvid.indexOf('av') === 0;
    const viewApi = isAv
      ? `https://api.bilibili.com/x/web-interface/view?aid=${bvid.substring(2)}`
      : `https://api.bilibili.com/x/web-interface/view?bvid=${bvid}`;
    const viewText = await Http.getText(viewApi, IOS_UA, 'https://www.bilibili.com/');
    if (viewText.length === 0) {
      return BilibiliService.failed(url, 'B站视频信息获取失败', true);
    }
    let title = '';
    let desc = '';
    let pic = '';
    let cid = 0;
    let author = '';
    try {
      const view = JSON.parse(viewText) as Record<string, Object>;
      const data = view['data'] as Record<string, Object>;
      if (data === undefined || data === null) {
        return BilibiliService.failed(url, 'B站视频不存在或已被删除');
      }
      title = typeof data['title'] === 'string' ? data['title'] as string : '';
      desc = typeof data['desc'] === 'string' ? data['desc'] as string : '';
      pic = typeof data['pic'] === 'string' ? data['pic'] as string : '';
      cid = typeof data['cid'] === 'number' ? data['cid'] as number : 0;
      const owner = data['owner'] as Record<string, Object>;
      if (owner !== undefined && owner !== null && typeof owner['name'] === 'string') {
        author = owner['name'] as string;
      }
      // 多 P：playurl 用第一个分 P 的 cid
      if (cid === 0 && Array.isArray(data['pages']) && (data['pages'] as Array<Object>).length > 0) {
        const p0 = (data['pages'] as Array<Record<string, Object>>)[0];
        if (typeof p0['cid'] === 'number') {
          cid = p0['cid'] as number;
        }
      }
    } catch (e) {
      return BilibiliService.failed(url, 'B站视频信息解析失败', true);
    }
    if (cid === 0) {
      return BilibiliService.failed(url, '未取得 B站视频 cid', true);
    }
    // 播放直链（html5 通道合成 mp4，免登录；v1.27.0 补 buvid3 握手 Cookie 防 403）
    const playApi = (isAv
      ? `https://api.bilibili.com/x/player/playurl?aid=${bvid.substring(2)}&cid=${cid}`
      : `https://api.bilibili.com/x/player/playurl?bvid=${bvid}&cid=${cid}`) +
      '&qn=64&type=MP4&platform=html5&high_quality=1';
    const biliHome = await Http.getFollow('https://www.bilibili.com/', CHROME_UA, '', 1,
      true, '', true);
    let videoUrl = '';
    try {
      const playResp = await Http.getFollow(playApi, CHROME_UA, 'https://www.bilibili.com/', 1,
        true, biliHome.cookies, false);
      const play = JSON.parse(playResp.text) as Record<string, Object>;
      const pdata = play['data'] as Record<string, Object>;
      if (pdata !== undefined && pdata !== null && Array.isArray(pdata['durl']) &&
        (pdata['durl'] as Array<Object>).length > 0) {
        const d0 = (pdata['durl'] as Array<Record<string, Object>>)[0];
        if (typeof d0['url'] === 'string') {
          videoUrl = d0['url'] as string;
        }
      }
    } catch (e) {
      // 落入下方兜底
    }
    if (videoUrl.length === 0 && html.length > 0) {
      // 兜底：页面 __playinfo__ 的 dash/baseUrl
      const key = '"baseUrl":"https://';
      const idx = html.indexOf(key);
      if (idx >= 0) {
        const start = html.indexOf('https://', idx);
        const end = html.indexOf('"', start);
        if (end > start) {
          videoUrl = html.substring(start, end);
        }
      }
    }
    if (videoUrl.length === 0) {
      const failed = BilibiliService.failed(url, '未取得 B站视频直链（部分视频需登录）', true);
      failed.title = title;
      return failed;
    }
    const result = new ParseResult();
    result.platform = Platform.BILIBILI;
    result.sourceUrl = target;
    result.status = ParseStatus.OK;
    result.noteId = bvid;
    result.title = title;
    result.shareText = desc;
    result.author = author;
    result.workType = WorkType.VIDEO;
    result.coverUrl = pic;
    const mi = new MediaItem();
    mi.url = videoUrl;
    mi.type = WorkType.VIDEO;
    result.mediaItems.push(mi);
    return result;
  }
}

export class MediaParser {
  /**
   * 通用链接提取：任何平台（小红书 / 抖音 / Instagram / TikTok / X）均可识别。
   * 要求"域名+路径"，避免把日期、版本号之类的文本误判为链接。
   */
  static extractAnyLinks(input: string): string[] {
    const out: string[] = [];
    if (input === null || input.length === 0) {
      return out;
    }
    // 尾部标点裁剪
    const trimJunk = (raw: string): string => {
      let end = raw.length;
      const junk = ')]}.,;!，。）】、；：';
      while (end > 0 && junk.indexOf(raw[end - 1]) >= 0) {
        end--;
      }
      return raw.substring(0, end);
    };
    const push = (link: string): void => {
      if (link.length > 0 && link.indexOf('/') >= 0 && out.indexOf(link) < 0) {
        out.push(link);
      }
    };
    // v1.26.0 精准提取：各平台严格白名单正则优先（X 必须是 status 帖子、
    // IG 必须是 p/reel/tv/share 路径），避免把个人主页/无关链接混进批量解析
    const strict: RegExp[] = [
      // X / Twitter：/user/status(es)/id（含 photo 子路径与查询参数）
      /(?:https?:\/\/)?(?:www\.|mobile\.)?(?:x|twitter)\.com\/[A-Za-z0-9_]{1,20}\/status(?:es)?\/\d+(?:\/photo\/\d+)?(?:\?[^\s"'<>，。；！？、【】《》\\^`{|}]*)?/gi,
      // X 短链 t.co（解析服务里跟跳还原）
      /(?:https?:\/\/)?t\.co\/[A-Za-z0-9]{5,}/gi,
      // Instagram：p / reel(s) / tv / share 短链路径
      /(?:https?:\/\/)?(?:[A-Za-z0-9-]+\.)*instagram\.com\/(?:p|reel|reels|tv|share)\/[A-Za-z0-9_-]+(?:\/photo)?(?:\/?[^\s"'<>，。；！？、【】《》\\^`{|}]*)?/gi,
      // Instagram 短链 instagr.am
      /(?:https?:\/\/)?instagr\.am\/(?:p|reel|reels|tv|share)\/[A-Za-z0-9_-]+(?:\/?[^\s"'<>，。；！？、【】《》\\^`{|}]*)?/gi,
      // 小红书 / rednote
      /(?:https?:\/\/)?(?:[A-Za-z0-9-]+\.)*(?:xiaohongshu\.com|rednote\.com)\/[^\s"'<>，。；！？、【】《》\\^`{|}]+/gi,
      /(?:https?:\/\/)?[A-Za-z0-9-]+\.?xhslink\.(?:com|cn)\/[^\s"'<>，。；！？、【】《》\\^`{|}]+/gi,
      // 抖音
      /(?:https?:\/\/)?(?:[A-Za-z0-9-]+\.)*(?:douyin\.com|iesdouyin\.com)\/[^\s"'<>，。；！？、【】《》\\^`{|}]+/gi,
      // TikTok
      /(?:https?:\/\/)?(?:www\.|vm\.|vt\.)?tiktok\.com\/[^\s"'<>，。；！？、【】《》\\^`{|}]+/gi,
      // B站 / b23 短链
      /(?:https?:\/\/)?(?:www\.|m\.)?bilibili\.com\/[^\s"'<>，。；！？、【】《》\\^`{|}]+/gi,
      /(?:https?:\/\/)?b23\.tv\/[A-Za-z0-9]+/gi,
      // 快手 / v 短链（含 chenzhongtech 分享域）
      /(?:https?:\/\/)?(?:[A-Za-z0-9-]+\.)*(?:kuaishou\.com|chenzhongtech\.com)\/[^\s"'<>，。；！？、【】《》\\^`{|}]*/gi
    ];
    for (const re of strict) {
      let m: RegExpExecArray | null = re.exec(input);
      while (m !== null) {
        const raw0 = m[0];
        const preceding = m.index > 0 ? input[m.index - 1] : '';
        const isWordish = (preceding >= 'a' && preceding <= 'z') ||
          (preceding >= 'A' && preceding <= 'Z') || (preceding >= '0' && preceding <= '9');
        if (!isWordish) {
          push(trimJunk(raw0));
        }
        m = re.exec(input);
      }
    }
    // 通用兜底：白名单没覆盖的其它链接（含裸域名无 scheme），保持旧行为
    const regex = /(?:https?:\/\/)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:\/[^\s"'<>，。；！？、【】《》\\^`{|}，]*)?/gi;
    let match: RegExpExecArray | null = regex.exec(input);
    while (match !== null) {
      const start = match.index;
      const raw0 = match[0];
      const preceding = start > 0 ? input[start - 1] : '';
      const isWordish = (preceding >= 'a' && preceding <= 'z') ||
        (preceding >= 'A' && preceding <= 'Z') || (preceding >= '0' && preceding <= '9') ||
        preceding === '.' || preceding === '_' || preceding === '-';
      if (!isWordish) {
        push(trimJunk(raw0));
      }
      match = regex.exec(input);
    }
    return out;
  }

  /** 取首个可识别平台的链接（自动跳过无关文本）。 */
  static firstSupportedLink(input: string): string {
    const links = MediaParser.extractAnyLinks(input);
    for (const link of links) {
      if (MediaParser.detect(link) !== Platform.UNKNOWN) {
        return link;
      }
    }
    return links.length > 0 ? links[0] : '';
  }

  static detect(url: string): Platform {
    if (url.indexOf('xiaohongshu.com') >= 0 || url.indexOf('xhslink.com') >= 0 || url.indexOf('xhslink.cn') >= 0) {
      return Platform.XHS;
    }
    if (DouyinService.isDouyinUrl(url)) {
      return Platform.DOUYIN;
    }
    if (InstagramService.isInstagramUrl(url)) {
      return Platform.INSTAGRAM;
    }
    if (TikTokService.isTikTokUrl(url)) {
      return Platform.TIKTOK;
    }
    if (XService.isXUrl(url)) {
      return Platform.X;
    }
    if (BilibiliService.isBilibiliUrl(url)) {
      return Platform.BILIBILI;
    }
    if (KuaishouService.isKuaishouUrl(url)) {
      return Platform.KUAISHOU;
    }
    return Platform.UNKNOWN;
  }

  static async parse(url: string): Promise<ParseResult> {
    const platform = MediaParser.detect(url);
    switch (platform) {
      case Platform.DOUYIN:
        return DouyinService.parse(url);
      case Platform.INSTAGRAM:
        return InstagramService.parse(url);
      case Platform.TIKTOK:
        return TikTokService.parse(url);
      case Platform.X:
        return XService.parse(url);
      case Platform.BILIBILI:
        return BilibiliService.parse(url);
      case Platform.KUAISHOU:
        return KuaishouService.parse(url);
      default: {
        const failed = new ParseResult();
        failed.sourceUrl = url;
        failed.status = ParseStatus.PARSE_FAILED;
        failed.message = '无法识别链接平台';
        return failed;
      }
    }
  }
}
