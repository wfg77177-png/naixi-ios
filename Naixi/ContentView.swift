import SwiftUI
import WebKit

// MARK: - JS injected into every Naixi page
// Safe features only: sign-in button click (once/day), dark mode, hide ads,
// keyword filter, fullscreen images, remember scroll position, section nav.
// localStorage holds ONLY the sign-in date guard + display settings
// (dark / hideAds / keywords). No session, token, cookie or credential
// is ever read or stored here; login state lives in the WKWebView
// system cookie jar. No auto-reply / auto-comment anywhere.
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
new MutationObserver(function(){ applyKeywords();}).observe(document.documentElement, {childList:true, subtree:true});

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
