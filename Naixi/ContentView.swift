import SwiftUI
import WebKit
import Photos
import AVFoundation

// MARK: - JS injected into every Naixi page
// Safe features only: sign-in button click (once/day), dark mode, hide ads,
// keyword filter, fullscreen images, remember scroll position, section nav,
// plus v2 batch A (all read-only or user-triggered): infinite scroll,
// read markers, only-OP, long-post folding, thread preview (long-press),
// Markdown export, PDF export, batch image save, read-aloud.
// localStorage holds ONLY the sign-in date guard + display settings
// (dark / hideAds / keywords / infinite / fold) + the read-thread id list
// ('nx_read'). No session, token, cookie or credential is ever read or
// stored here; login state lives in the WKWebView system cookie jar.
// No auto-reply / auto-comment anywhere.
//
// Speed: the injected JS is split in two. nxJSStart (atDocumentStart)
// carries ONLY the dark-mode + ad-hide CSS so the page never white-flashes.
// nxJS (atDocumentEnd) carries the interactive features and is re-run
// after webView didFinish. Both are forMainFrameOnly: true so they do
// not re-execute inside every ad iframe.

// ---------- Script A: atDocumentStart, CSS only (kills white flash) ----------
private let nxJSStart = """
(function(){
function read(k,d){ try{ var v=localStorage.getItem('nx_'+k); return v===null?d:v;}catch(e){ return d;}}
if (read('dark','0')==='1' &&!document.getElementById('nx-dark-style')){
var s=document.createElement('style'); s.id='nx-dark-style';
s.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f!important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
document.documentElement.appendChild(s);
}
if (read('hideAds','1')==='1' &&!document.getElementById('nx-ad-style')){
var s2=document.createElement('style'); s2.id='nx-ad-style';
s2.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none!important;}';
document.documentElement.appendChild(s2);
}
})();
"""

// ---------- Script B: atDocumentEnd, interactive features ----------
private let nxJS = """
(function(){
function store(k,v){ try{ localStorage.setItem('nx_'+k, v);}catch(e){}}
function read(k,d){ try{ var v=localStorage.getItem('nx_'+k); return v===null?d:v;}catch(e){ return d;}}

function showToast(msg){
var t=document.createElement('div');
t.textContent=msg;
t.style.cssText='position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,0.82);color:#fff;padding:10px 16px;border-radius:20px;font-size:14px;z-index:999999;pointer-events:none;';
document.body.appendChild(t);
setTimeout(function(){ t.remove();}, 2600);
}
window.__nxToast = showToast;

// ---------- 1. Sign-in: click the forum's own sign-in button ----------
// The forum sign-in endpoint is unverified, so no API call is made.
// This only clicks the button the site itself renders, using the
// webview's own session cookie. At most once per day (date guard).
// Auto sign-in runs ONLY from webView didFinish (never from a
// half-loaded or challenge page); the manual toolbar button works
// any time the user taps it.
function findSignInEl(){
var els = document.querySelectorAll('a, button');
for (var i=0;i<els.length;i++){
var t=(els[i].textContent||'').trim();
if(t==='签到' || t==='每日签到' || t.indexOf('签到')===0){ return els[i];}
}
var imgs = document.querySelectorAll('img[alt*="签到"], img[title*="签到"]');
for (var j=0;j<imgs.length;j++){
var a=imgs[j].closest('a'); if(a) return a;
}
return null;
}
window.__nxClickSignIn = function(manual){
var el = findSignInEl();
if(!el){
if(manual) showToast('未找到签到按钮，请在页面里点签到');
return false;
}
el.click();
store('signDate', new Date().toISOString().slice(0,10));
if(manual) showToast('已点签到');
return true;
};
window.__nxAutoSignIn = function(){
var p = location.pathname;
var isIndex = (p==='/' || p==='/forum.php' || p.indexOf('forum.php')!==-1);
if(!isIndex) return;
var today = new Date().toISOString().slice(0,10);
if (read('signDate','') === today) return;
setTimeout(function(){
var el = findSignInEl();
if(el){ el.click(); store('signDate', today);}
}, 1200);
};

// ---------- 2. Dark mode ----------
window.__nxSetDark = function(on){
store('dark', on?'1':'0');
var id='nx-dark-style', el=document.getElementById(id);
if(on){
if(!el){
el=document.createElement('style'); el.id=id;
el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f!important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
document.documentElement.appendChild(el);
}
} else if(el){ el.remove();}
};

// ---------- 3. Hide ads / promo blocks ----------
window.__nxSetHideAds = function(on){
store('hideAds', on?'1':'0');
var id='nx-ad-style', el=document.getElementById(id);
if(on){
if(!el){
el=document.createElement('style'); el.id=id;
el.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none!important;}';
document.documentElement.appendChild(el);
}
} else if(el){ el.remove();}
};

// ---------- 4. Keyword filter (Discuz thread links) ----------
window.__nxSetKeywords = function(csv){
store('keywords', csv||'');
applyKeywords();
};
function applyKeywords(){
var csv = read('keywords','');
var kws = csv.split(',').map(function(s){ return s.trim();}).filter(function(s){ return s.length>0;});
var rows = document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
rows.forEach(function(a){
var row = a.closest('li, article, div');
if(!row) return;
var txt = (a.textContent||'');
var hit = kws.some(function(k){ return txt.indexOf(k)!== -1;});
row.style.display = hit? 'none': '';
});
}
window.__nxApplyKeywords = applyKeywords;
applyKeywords();
new MutationObserver(function(){ applyKeywords(); applyReadMarks(); applyFolding();}).observe(document.documentElement, {childList:true, subtree:true});

// ---------- 5. Fullscreen image viewer ----------
document.addEventListener('click', function(e){
var img = e.target.closest? e.target.closest('img'): null;
if(!img ||!img.src) return;
if(img.closest('a')) return;
var ov=document.createElement('div');
ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.92);z-index:999999;display:flex;align-items:center;justify-content:center;';
var im=document.createElement('img');
im.src=img.src; im.style.cssText='max-width:96vw;max-height:92vh;object-fit:contain;';
ov.appendChild(im);
ov.addEventListener('click', function(){ ov.remove();});
document.body.appendChild(ov);
}, true);

// ---------- 6. Remember scroll position (per URL) ----------
var saveTimer=null;
function savePos(){
try{ sessionStorage.setItem('nx_pos_'+location.pathname, String(window.scrollY));}catch(e){}
}
window.addEventListener('scroll', function(){
if(saveTimer) clearTimeout(saveTimer);
saveTimer=setTimeout(savePos, 400);
}, {passive:true});
window.addEventListener('pagehide', savePos);
window.__nxRestorePos = function(){
try{
var y=parseInt(sessionStorage.getItem('nx_pos_'+location.pathname)||'0',10);
if(y>200){ setTimeout(function(){ window.scrollTo(0,y);}, 350);}
}catch(e){}
};
window.__nxRestorePos();

// ---------- 7. Section navigation (tap a board name in the native picker) ----------
// Board names are verified from the live homepage; links are found by
// name (brackets stripped), never by hardcoded board URLs.
window.__nxGoSection = function(name){
var links = Array.prototype.slice.call(document.querySelectorAll('a'));
function clean(t){ return (t||'').replace(/[\\[\\]\\s]/g,'');}
var cands = links.filter(function(a){
var href = a.getAttribute('href')||'';
return clean(a.textContent)===name && href && href.indexOf('/')===0;
});
if(!cands.length) return false;
var hit = cands.find(function(a){
var h=a.getAttribute('href')||'';
return h.indexOf('forum')!==-1 || h.indexOf('fid=')!==-1;
}) || cands[0];
hit.click(); return true;
};

// ---------- 8. Shortcut links (found by name, never hardcoded URLs) ----------
window.__nxGoLink = function(word){
var links = Array.prototype.slice.call(document.querySelectorAll('a'));
var hit = links.find(function(a){
var t=(a.textContent||'').trim();
return t.indexOf(word)!==-1 && a.getAttribute('href');
});
if(hit){ hit.click(); return true;}
return false;
};

// ---------- 9. Back to top ----------
window.__nxTop = function(){ window.scrollTo({top:0, behavior:'smooth'});};

// ---------- 10. Read markers (clicked threads dim) ----------
// localStorage 'nx_read' holds ONLY an array of read thread ids.
// No session/token/cookie is ever stored here.
function threadIdFromHref(h){
var m = h.match(/thread-(\\d+)/) || h.match(/[?&]tid=(\\d+)/);
return m ? m[1] : null;
}
function getReadSet(){
try{ return JSON.parse(localStorage.getItem('nx_read')||'[]');}catch(e){ return [];}
}
function applyReadMarks(){
var set = getReadSet();
if(!set.length) return;
var rows = document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
rows.forEach(function(a){
var id = threadIdFromHref(a.getAttribute('href')||'');
if(!id) return;
if(set.indexOf(id)!==-1){
var row = a.closest('li, article, div, tr');
if(row){ row.style.opacity='0.45';}
}
});
}
document.addEventListener('click', function(e){
var a = e.target.closest ? e.target.closest('a[href*="thread-"], a[href*="mod=viewthread"]') : null;
if(!a) return;
var id = threadIdFromHref(a.getAttribute('href')||'');
if(!id) return;
var set = getReadSet();
if(set.indexOf(id)===-1){
set.push(id);
if(set.length>500) set = set.slice(-500);
try{ localStorage.setItem('nx_read', JSON.stringify(set));}catch(e){}
}
}, true);
window.__nxClearRead = function(){
try{ localStorage.removeItem('nx_read');}catch(e){}
document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]').forEach(function(a){
var row = a.closest('li, article, div, tr');
if(row){ row.style.opacity='';}
});
showToast('已清空已读记录');
};
applyReadMarks();

// ---------- 11. Infinite scroll (append next list page) ----------
var nxInfinite = read('infinite','1')==='1';
var nxLoadingNext = false;
window.__nxSetInfinite = function(on){ store('infinite', on?'1':'0'); nxInfinite = !!on; };
function isListPage(){
return !!document.querySelector('#threadlisttableid, #threadlist, .threadlist') || location.href.indexOf('mod=forumdisplay')!==-1 || /forum-\\d+-\\d+\\.html/.test(location.pathname);
}
function nextPageLink(){
var nxt = document.querySelector('a.nxt');
if(nxt && nxt.getAttribute('href')) return nxt;
var links = document.querySelectorAll('a[href*="page="]');
for(var i=0;i<links.length;i++){
var t=(links[i].textContent||'').trim();
if(t.indexOf('下一页')!==-1) return links[i];
}
return null;
}
function appendNextPage(){
if(!nxInfinite || nxLoadingNext || !isListPage()) return;
var link = nextPageLink();
if(!link) return;
var url = link.getAttribute('href');
if(!url) return;
if(url.indexOf('http')!==0){ url = new URL(url, location.href).href; }
nxLoadingNext = true;
fetch(url, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
var doc = new DOMParser().parseFromString(html, 'text/html');
var table = document.querySelector('#threadlisttableid');
var newTable = doc.querySelector('#threadlisttableid');
if(table && newTable){
Array.prototype.slice.call(newTable.querySelectorAll('tbody')).forEach(function(tb){
if(tb.id && tb.id.indexOf('stickthread')===0) return;
table.appendChild(document.importNode(tb, true));
});
} else {
var container = document.querySelector('#threadlist, .threadlist');
var newContainer = doc.querySelector('#threadlist, .threadlist');
if(container && newContainer){
Array.prototype.slice.call(newContainer.children).forEach(function(ch){
container.appendChild(document.importNode(ch, true));
});
}
}
var newNext = doc.querySelector('a.nxt');
var newHref = newNext ? newNext.getAttribute('href') : null;
document.querySelectorAll('a.nxt').forEach(function(n){
if(newHref){ n.setAttribute('href', newHref); } else { n.remove(); }
});
applyKeywords(); applyReadMarks(); applyFolding();
nxLoadingNext = false;
}).catch(function(){ nxLoadingNext = false; });
}
window.addEventListener('scroll', function(){
if(!nxInfinite || nxLoadingNext) return;
if((window.innerHeight + window.scrollY) > document.body.scrollHeight - 600){ appendNextPage(); }
}, {passive:true});

// ---------- 12. Long-post folding ----------
var nxFold = read('fold','1')==='1';
window.__nxSetFold = function(on){ store('fold', on?'1':'0'); nxFold = !!on; if(on) applyFolding(); else unfoldAll(); };
function unfoldAll(){
document.querySelectorAll('[data-nx-folded="1"]').forEach(function(el){
el.style.maxHeight=''; el.style.overflow=''; el.removeAttribute('data-nx-folded');
});
document.querySelectorAll('.nx-expand-btn').forEach(function(b){ b.remove(); });
}
function applyFolding(){
if(!nxFold) return;
var posts = document.querySelectorAll('.t_f');
posts.forEach(function(el){
if(el.getAttribute('data-nx-folded')) return;
var txt = el.innerText || '';
if(txt.length < 1500) return;
el.setAttribute('data-nx-folded','1');
el.style.maxHeight='420px'; el.style.overflow='hidden';
var anchor = el.closest('.pct') || el.closest('div[id^="post_"]');
var btn = document.createElement('button');
btn.className='nx-expand-btn';
btn.textContent='展开全文';
btn.style.cssText='display:block;margin:8px auto;padding:6px 18px;border-radius:16px;border:1px solid #888;background:#fff;color:#333;font-size:14px;';
btn.addEventListener('click', function(){
el.style.maxHeight=''; el.style.overflow='';
btn.remove();
});
if(anchor && anchor.parentNode){ anchor.parentNode.insertBefore(btn, anchor.nextSibling); }
else { el.appendChild(btn); }
});
}
applyFolding();

// ---------- 13. Only OP (toggle authorid filter) ----------
window.__nxOnlyOP = function(){
var u = new URL(location.href);
if(u.searchParams.get('authorid')){ u.searchParams.delete('authorid'); location.href = u.href; return; }
var first = document.querySelector('div[id^="post_"] a[href*="space-uid-"], div[id^="post_"] a[href*="uid="]');
var uid = null;
if(first){
var h = first.getAttribute('href')||'';
var m = h.match(/space-uid-(\\d+)/) || h.match(/[?&]uid=(\\d+)/);
if(m) uid = m[1];
}
if(!uid){ showToast('未找到楼主信息'); return; }
u.searchParams.set('authorid', uid);
location.href = u.href;
};

// ---------- 14. Thread text / Markdown export / image collection ----------
function htmlToMd(root){
var clone = root.cloneNode(true);
clone.querySelectorAll('img').forEach(function(im){
var src = im.getAttribute('data-original') || im.getAttribute('data-src') || im.getAttribute('src') || '';
var alt = im.getAttribute('alt') || '图片';
im.replaceWith(document.createTextNode('\\n![' + alt + '](' + src + ')\\n'));
});
clone.querySelectorAll('a').forEach(function(a){
var href = a.getAttribute('href')||'';
var txt = (a.textContent||'').trim();
a.replaceWith(document.createTextNode(txt ? '[' + txt + '](' + href + ')' : href));
});
clone.querySelectorAll('br').forEach(function(br){ br.replaceWith(document.createTextNode('\\n')); });
clone.querySelectorAll('p, div, tr').forEach(function(el){ el.appendChild(document.createTextNode('\\n')); });
var s = clone.innerText || '';
return s.replace(/\\n{3,}/g, '\\n\\n').trim();
}
window.__nxThreadText = function(){
var title = '';
var t = document.querySelector('#thread_subject');
if(t) title = (t.textContent||'').trim();
var parts = [];
if(title) parts.push(title);
document.querySelectorAll('.t_f').forEach(function(el){
var s = (el.innerText||'').trim();
if(s) parts.push(s);
});
return parts.join('\\n\\n').slice(0, 12000);
};
window.__nxExportMarkdown = function(){
var title = '';
var t = document.querySelector('#thread_subject');
if(t) title = (t.textContent||'').trim();
var lines = [];
if(title) lines.push('# ' + title, '');
document.querySelectorAll('div[id^="post_"]').forEach(function(post){
var a = post.querySelector('.pls a.xw1, .authi a.xw1');
var author = a ? (a.textContent||'').trim() : '';
var body = post.querySelector('.t_f');
if(!body) return;
var md = htmlToMd(body);
if(!md) return;
if(author) lines.push('## ' + author, '');
lines.push(md, '', '---', '');
});
return lines.join('\\n');
};
window.__nxCollectImages = function(){
var urls = [];
document.querySelectorAll('.t_f img, .pct img').forEach(function(im){
var src = im.getAttribute('data-original') || im.getAttribute('data-src') || im.getAttribute('src') || '';
if(!src || src.indexOf('http')!==0) return;
if(src.indexOf('avatar')!==-1) return;
if(im.naturalWidth && im.naturalWidth < 120) return;
if(urls.indexOf(src)===-1) urls.push(src);
});
return JSON.stringify(urls.slice(0, 50));
};

// ---------- 15. Long-press thread preview ----------
(function(){
var pvTimer = null, pvX = 0, pvY = 0, pvA = null;
function pvCancel(){ if(pvTimer){ clearTimeout(pvTimer); pvTimer = null; } }
var noCallout = document.createElement('style');
noCallout.textContent='a[href*="thread-"],a[href*="mod=viewthread"]{-webkit-touch-callout:none;}';
document.documentElement.appendChild(noCallout);
document.addEventListener('touchstart', function(e){
pvCancel();
var a = e.target.closest ? e.target.closest('a[href*="thread-"], a[href*="mod=viewthread"]') : null;
if(!a || !e.touches || e.touches.length!==1) return;
pvA = a; pvX = e.touches[0].clientX; pvY = e.touches[0].clientY;
pvTimer = setTimeout(function(){ pvTimer = null; pvShowPreview(pvA); }, 650);
}, {passive:true});
document.addEventListener('touchmove', function(e){
if(!pvTimer) return;
var t = e.touches[0];
if(Math.abs(t.clientX-pvX) > 12 || Math.abs(t.clientY-pvY) > 12) pvCancel();
}, {passive:true});
document.addEventListener('touchend', pvCancel, {passive:true});
function pvShowPreview(a){
var href = a.getAttribute('href');
if(!href) return;
var url = href.indexOf('http')===0 ? href : new URL(href, location.href).href;
fetch(url, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
var doc = new DOMParser().parseFromString(html, 'text/html');
var first = doc.querySelector('.t_f');
var txt = first ? (first.innerText||'').trim().slice(0, 300) : '（无预览）';
var title = (a.textContent||'').trim();
var ov = document.createElement('div');
ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:999998;display:flex;align-items:flex-end;justify-content:center;';
var card = document.createElement('div');
card.style.cssText = 'background:#fff;color:#111;border-radius:18px 18px 0 0;padding:18px;max-height:55vh;overflow:auto;width:100%;font-size:15px;line-height:1.6;';
var h = document.createElement('div');
h.textContent = title; h.style.cssText='font-weight:700;margin-bottom:8px;';
var p = document.createElement('p'); p.textContent = txt; p.style.margin='0';
var open = document.createElement('button');
open.textContent='打开帖子'; open.style.cssText='margin-top:14px;width:100%;padding:10px;border-radius:12px;border:none;background:#007aff;color:#fff;font-size:16px;';
open.addEventListener('click', function(){ ov.remove(); a.click(); });
card.appendChild(h); card.appendChild(p); card.appendChild(open);
ov.appendChild(card);
ov.addEventListener('click', function(e){ if(e.target===ov) ov.remove(); });
document.body.appendChild(ov);
}).catch(function(){ showToast('预览加载失败'); });
}
})();
})();
"""

// MARK: - Model
final class BrowserModel: ObservableObject {
weak var webView: WKWebView?
@Published var isDark = false
@Published var fontScale: CGFloat = 1.0
@Published var hideAds = true
@Published var keywords = ""
@Published var canGoBack = false
// v2 batch A: safe features (read-only or user-triggered)
@Published var isSpeaking = false
@Published var infiniteScroll = true
@Published var foldLongPosts = true
private let speech = AVSpeechSynthesizer()

init() {
speech.delegate = self
}

let homeURL = URL(string: "https://forum.naixi.net/")!
let newAPIURL = URL(string: "https://newapi.naixi.net/")!
// Board names verified from the live homepage (2026-11-17).
let sections = ["eSIM","日常","技术","推广","运营商","人工智能","问答","交易","果粉","开户","宽带症候群","市场"]

func load(_ url: URL) {
webView?.load(URLRequest(url: url))
}
func goHome() { load(homeURL)}
func goNewAPI() { load(newAPIURL)}
func reload() { webView?.reload()}
func goBack() { webView?.goBack()}
func backToTop() {
webView?.evaluateJavaScript("window.__nxTop && window.__nxTop();", completionHandler: nil)
}
func goSection(_ name: String) {
webView?.evaluateJavaScript("window.__nxGoSection && window.__nxGoSection('\(name)');") { _, _ in}
}
func goMall() {
webView?.evaluateJavaScript("window.__nxGoLink && window.__nxGoLink('商城');") { ok, _ in
if let found = ok as? Bool,!found {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('未找到积分商城入口');", completionHandler: nil)
}
}
}
func setDark(_ on: Bool) {
isDark = on
UserDefaults.standard.set(on, forKey: "nx_dark")
webView?.evaluateJavaScript("window.__nxSetDark && window.__nxSetDark(\(on? "true": "false"));", completionHandler: nil)
}
func setFontScale(_ s: CGFloat) {
fontScale = s
UserDefaults.standard.set(Double(s), forKey: "nx_fontScale")
webView?.pageZoom = s
}
func setHideAds(_ on: Bool) {
hideAds = on
UserDefaults.standard.set(on, forKey: "nx_hideAds")
webView?.evaluateJavaScript("window.__nxSetHideAds && window.__nxSetHideAds(\(on? "true": "false"));", completionHandler: nil)
}
func setKeywords(_ s: String) {
keywords = s
UserDefaults.standard.set(s, forKey: "nx_keywords")
let esc = s.replacingOccurrences(of: "'", with: "\\'")
webView?.evaluateJavaScript("window.__nxSetKeywords && window.__nxSetKeywords('\(esc)');", completionHandler: nil)
}
func manualSignIn() {
webView?.evaluateJavaScript("window.__nxClickSignIn && window.__nxClickSignIn(true);", completionHandler: nil)
}

// MARK: - v2 batch A: safe features (read-only or user-triggered)
func setInfiniteScroll(_ on: Bool) {
infiniteScroll = on
UserDefaults.standard.set(on, forKey: "nx_infinite")
webView?.evaluateJavaScript("window.__nxSetInfinite && window.__nxSetInfinite(\(on ? "true" : "false"));", completionHandler: nil)
}
func setFoldLongPosts(_ on: Bool) {
foldLongPosts = on
UserDefaults.standard.set(on, forKey: "nx_fold")
webView?.evaluateJavaScript("window.__nxSetFold && window.__nxSetFold(\(on ? "true" : "false"));", completionHandler: nil)
}
func clearReadHistory() {
webView?.evaluateJavaScript("window.__nxClearRead && window.__nxClearRead();", completionHandler: nil)
}
func toggleOnlyOP() {
webView?.evaluateJavaScript("window.__nxOnlyOP && window.__nxOnlyOP();", completionHandler: nil)
}
func exportMarkdown() {
webView?.evaluateJavaScript("window.__nxExportMarkdown && window.__nxExportMarkdown();") { result, _ in
guard let md = result as? String, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('当前页没有可导出的帖子');", completionHandler: nil)
return
}
let url = FileManager.default.temporaryDirectory.appendingPathComponent("naixi-thread.md")
try? md.write(to: url, atomically: true, encoding: .utf8)
self.presentShare(items: [url])
}
}
func exportPDF() {
guard let wv = webView else { return }
wv.createPDF(configuration: WKPDFConfiguration()) { result in
switch result {
case .success(let data):
let url = FileManager.default.temporaryDirectory.appendingPathComponent("naixi-page.pdf")
try? data.write(to: url)
self.presentShare(items: [url])
case .failure:
wv.evaluateJavaScript("window.__nxToast && window.__nxToast('生成 PDF 失败');", completionHandler: nil)
}
}
}
func savePageImages() {
webView?.evaluateJavaScript("window.__nxCollectImages && window.__nxCollectImages();") { result, _ in
guard let json = result as? String,
let data = json.data(using: .utf8),
let urls = try? JSONDecoder().decode([String].self, from: data),
!urls.isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('本页没有可保存的图片');", completionHandler: nil)
return
}
self.saveImagesToPhotos(urls)
}
}
private func saveImagesToPhotos(_ urls: [String]) {
PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
guard status == .authorized || status == .limited else {
DispatchQueue.main.async {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('未获得相册权限');", completionHandler: nil)
}
return
}
let group = DispatchGroup()
let lock = NSLock()
var saved = 0
for u in urls {
guard let url = URL(string: u) else { continue }
group.enter()
URLSession.shared.dataTask(with: url) { data, _, _ in
defer { group.leave() }
guard let data = data, let img = UIImage(data: data) else { return }
let sem = DispatchSemaphore(value: 0)
PHPhotoLibrary.shared().performChanges({
PHAssetChangeRequest.creationRequestForAsset(from: img)
}) { ok, _ in
if ok { lock.lock(); saved += 1; lock.unlock() }
sem.signal()
}
sem.wait()
}.resume()
}
group.notify(queue: .main) {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('已保存 \(saved) 张图片到相册');", completionHandler: nil)
}
}
}
func toggleSpeak() {
if speech.isSpeaking {
speech.stopSpeaking(at: .immediate)
isSpeaking = false
return
}
webView?.evaluateJavaScript("window.__nxThreadText && window.__nxThreadText();") { result, _ in
guard let text = result as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('当前页没有可朗读的正文');", completionHandler: nil)
return
}
let utterance = AVSpeechUtterance(string: text)
utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
utterance.rate = AVSpeechUtteranceDefaultSpeechRate
self.isSpeaking = true
self.speech.speak(utterance)
}
}
func presentShare(items: [Any]) {
guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
var top = root
while let presented = top.presentedViewController { top = presented }
let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
if let pop = vc.popoverPresentationController {
pop.sourceView = top.view
pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
pop.permittedArrowDirections = []
}
top.present(vc, animated: true)
}
}

// MARK: - AVSpeechSynthesizerDelegate (reset speaking state)
extension BrowserModel: AVSpeechSynthesizerDelegate {
func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
DispatchQueue.main.async { self.isSpeaking = false }
}
func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
DispatchQueue.main.async { self.isSpeaking = false }
}
}

// MARK: - ContentView
struct ContentView: View {
@StateObject private var model = BrowserModel()
@State private var showSections = false
@State private var showSettings = false

var body: some View {
ZStack(alignment:.bottom) {
WebView(model: model)
.ignoresSafeArea(edges:.top)
BottomBar(model: model, showSections: $showSections, showSettings: $showSettings)
.padding(.horizontal, 10)
.padding(.bottom, 8)
}
.sheet(isPresented: $showSections) { SectionSheet(model: model)}
.sheet(isPresented: $showSettings) { SettingsSheet(model: model)}
.onAppear {
model.isDark = UserDefaults.standard.bool(forKey: "nx_dark")
model.hideAds = UserDefaults.standard.object(forKey: "nx_hideAds") as? Bool?? true
model.keywords = UserDefaults.standard.string(forKey: "nx_keywords")?? ""
let fs = UserDefaults.standard.double(forKey: "nx_fontScale")
if fs > 0 { model.fontScale = CGFloat(fs)}
model.infiniteScroll = UserDefaults.standard.object(forKey: "nx_infinite") as? Bool ?? true
model.foldLongPosts = UserDefaults.standard.object(forKey: "nx_fold") as? Bool ?? true
}
}
}

// MARK: - WebView
// Speed: the WKWebView is the eager root view — created as soon as the
// app opens and loading the forum homepage immediately, without waiting
// for the toolbar or settings to be read. The data store is explicitly
// the default persistent one (cache + cookies persist across launches;
// repeat opens reuse the cache and the Cloudflare cf_clearance cookie
// to skip re-verification). Cache/cookies are never cleared, the store
// is never.nonPersistent(), and reloads never ignore the local cache.
// No custom UA, no second pre-warm webview, no URLCache tuning
// (ineffective for WKWebView), no prefetch/preload.
struct WebView: UIViewRepresentable {
@ObservedObject var model: BrowserModel

func makeCoordinator() -> Coordinator { Coordinator(model: model)}

func makeUIView(context: Context) -> WKWebView {
let config = WKWebViewConfiguration()
config.websiteDataStore = WKWebsiteDataStore.default()
config.allowsInlineMediaPlayback = true
config.mediaTypesRequiringUserActionForPlayback = []
let startScript = WKUserScript(source: nxJSStart, injectionTime:.atDocumentStart, forMainFrameOnly: true)
let endScript = WKUserScript(source: nxJS, injectionTime:.atDocumentEnd, forMainFrameOnly: true)
config.userContentController.addUserScript(startScript)
config.userContentController.addUserScript(endScript)
let webView = WKWebView(frame:.zero, configuration: config)
webView.navigationDelegate = context.coordinator
webView.allowsBackForwardNavigationGestures = true
webView.scrollView.bounces = true
webView.scrollView.contentInsetAdjustmentBehavior =.always
// leave room so the last line is never hidden behind the bottom bar
webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
if model.fontScale!= 1.0 { webView.pageZoom = model.fontScale}
webView.load(URLRequest(url: model.homeURL))
model.webView = webView
return webView
}

func updateUIView(_ webView: WKWebView, context: Context) {}

class Coordinator: NSObject, WKNavigationDelegate {
let model: BrowserModel
init(model: BrowserModel) { self.model = model}
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
model.canGoBack = webView.canGoBack
// Apply the saved font size now that the page is loaded
// (makeUIView runs before onAppear restores it).
if model.fontScale!= 1.0 { webView.pageZoom = model.fontScale}
// Re-run the late-bound features now the page is truly loaded
// (not on a half-loaded or challenge page): keyword filter,
// scroll restore, and the once-per-day auto sign-in.
webView.evaluateJavaScript(
"window.__nxApplyKeywords && window.__nxApplyKeywords();" +
"window.__nxRestorePos && window.__nxRestorePos();" +
"window.__nxAutoSignIn && window.__nxAutoSignIn();",
completionHandler: nil)
}
func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
model.canGoBack = webView.canGoBack
}
}
}

// MARK: - Bottom bar (comfortable proportions, smooth)
struct BottomBar: View {
@ObservedObject var model: BrowserModel
@Binding var showSections: Bool
@Binding var showSettings: Bool

var body: some View {
HStack(spacing: 2) {
BarButton(icon: "house", label: "首页") { model.goHome()}
BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true}
BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn()}
BarButton(icon: "bolt", label: "API") { model.goNewAPI()}
BarButton(icon: model.isDark? "moon.fill": "moon", label: "深色") {
model.setDark(!model.isDark)
}
BarButton(icon: "arrow.up", label: "顶部") { model.backToTop()}
BarButton(icon: "gearshape", label: "设置") { showSettings = true}
}
.padding(.vertical, 8)
.padding(.horizontal, 4)
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style:.continuous))
.shadow(color:.black.opacity(0.12), radius: 12, x: 0, y: 4)
}
}

struct BarButton: View {
let icon: String
let label: String
let action: () -> Void
var body: some View {
Button(action: action) {
VStack(spacing: 3) {
Image(systemName: icon)
.font(.system(size: 18, weight:.medium))
Text(label)
.font(.system(size: 10, weight:.medium))
}
.frame(maxWidth:.infinity, minHeight: 44)
.contentShape(Rectangle())
}
.buttonStyle(.plain)
.foregroundStyle(.primary)
}
}

// MARK: - Section picker sheet
struct SectionSheet: View {
@ObservedObject var model: BrowserModel
@Environment(\.dismiss) private var dismiss

let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

var body: some View {
NavigationStack {
ScrollView {
LazyVGrid(columns: columns, spacing: 12) {
ForEach(model.sections, id: \.self) { name in
Button {
model.goSection(name)
dismiss()
} label: {
Text(name)
.font(.system(size: 16, weight:.medium))
.frame(maxWidth:.infinity, minHeight: 52)
.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style:.continuous))
}
.buttonStyle(.plain)
}
}
.padding(16)
}
.navigationTitle("分区")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
ToolbarItem(placement:.cancellationAction) {
Button("关闭") { dismiss()}
}
}
}
.presentationDetents([.medium])
}
}

// MARK: - Settings sheet
struct SettingsSheet: View {
@ObservedObject var model: BrowserModel
@Environment(\.dismiss) private var dismiss
@State private var keywordsText = ""

var body: some View {
NavigationStack {
Form {
Section("阅读") {
HStack {
Text("字体大小")
Spacer()
Stepper("", value: Binding(
get: { model.fontScale},
set: { model.setFontScale($0)}
), in: 0.85...1.35, step: 0.05)
Text(String(format: "%.0f%%", model.fontScale * 100))
.foregroundStyle(.secondary)
.frame(width: 48, alignment:.trailing)
}
Toggle("深色模式", isOn: Binding(
get: { model.isDark},
set: { model.setDark($0)}
))
Toggle("隐藏广告与推广位", isOn: Binding(
get: { model.hideAds},
set: { model.setHideAds($0)}
))
}
Section("屏蔽关键词") {
TextField("多个关键词用英文逗号隔开", text: $keywordsText)
.onChange(of: keywordsText) { model.setKeywords($0)}
Text("包含这些词的帖子标题会被隐藏。")
.font(.footnote)
.foregroundStyle(.secondary)
}
Section("当前帖子") {
Button("只看楼主 / 显示全部") { model.toggleOnlyOP(); dismiss() }
Button("导出 Markdown") { model.exportMarkdown() }
Button("转 PDF") { model.exportPDF() }
Button("保存本页图片到相册") { model.savePageImages(); dismiss() }
Button(model.isSpeaking ? "停止朗读" : "朗读本页") { model.toggleSpeak(); dismiss() }
}
Section("阅读记录") {
Button("清空已读记录") { model.clearReadHistory() }
Toggle("无缝翻页", isOn: Binding(
get: { model.infiniteScroll },
set: { model.setInfiniteScroll($0) }
))
Toggle("长文折叠", isOn: Binding(
get: { model.foldLongPosts },
set: { model.setFoldLongPosts($0) }
))
}
Section("快捷入口") {
Button("New API 签到（每天 1–2 刀）") { model.goNewAPI(); dismiss()}
Button("积分商城") { model.goMall(); dismiss()}
Button("签到") { model.manualSignIn(); dismiss()}
}
Section {
Button("刷新页面") { model.reload(); dismiss()}
Button("回到首页") { model.goHome(); dismiss()}
}
}
.navigationTitle("设置")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
ToolbarItem(placement:.confirmationAction) {
Button("完成") { dismiss()}
}
}
.onAppear { keywordsText = model.keywords}
}
.presentationDetents([.medium,.large])
}
}
