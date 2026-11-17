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
new MutationObserver(function(){ applyKeywords(); applyReadMarks(); applyFolding(); applyUserMarks(); applyHighlight(); nxSetupCodeBlocks();}).observe(document.documentElement, {childList:true, subtree:true});

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
applyKeywords(); applyReadMarks(); applyFolding(); applyUserMarks(); applyHighlight(); nxSetupCodeBlocks();
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

// ---------- 16. User notes + blacklist ----------
// localStorage 'nx_notes' = {username: note}; 'nx_blocked' = [username].
// Display-only changes; nothing is ever posted.
function getNotes(){ try{ return JSON.parse(localStorage.getItem('nx_notes')||'{}'); }catch(e){ return {}; } }
function getBlocked(){ try{ return JSON.parse(localStorage.getItem('nx_blocked')||'[]'); }catch(e){ return []; } }
function applyUserMarks(){
document.querySelectorAll('.nx-note-badge').forEach(function(b){ b.remove(); });
document.querySelectorAll('[data-nx-hidden="1"]').forEach(function(el){ el.style.display=''; el.removeAttribute('data-nx-hidden'); });
var notes = getNotes(), blocked = getBlocked();
var hasNotes = Object.keys(notes).length>0, hasBlocked = blocked.length>0;
if(!hasNotes && !hasBlocked) return;
document.querySelectorAll('a[href*="space-uid-"], a[href*="uid="]').forEach(function(a){
var name = (a.textContent||'').trim();
if(!name) return;
if(hasBlocked && blocked.indexOf(name)!==-1){
var post = a.closest('div[id^="post_"]');
if(post){ post.style.display='none'; post.setAttribute('data-nx-hidden','1'); return; }
var row = a.closest('tr, li');
if(row){ row.style.display='none'; row.setAttribute('data-nx-hidden','1'); }
return;
}
if(hasNotes && notes[name]){
var s = document.createElement('span');
s.className='nx-note-badge';
s.textContent = ' ' + notes[name];
s.style.cssText='background:#fff3bf;color:#7a5b00;font-size:12px;border-radius:4px;padding:1px 5px;margin-left:4px;';
a.parentNode.insertBefore(s, a.nextSibling);
}
});
}
window.__nxSetNotes = function(json){ store('notes', json||'{}'); applyUserMarks(); };
window.__nxSetBlocked = function(json){ store('blocked', json||'[]'); applyUserMarks(); };
applyUserMarks();

// ---------- 17. Keyword highlight (separate from the filter list) ----------
function escHtml(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function hlHtml(txt, kws){
var parts = [txt], found = false;
kws.forEach(function(k){
var next = [];
parts.forEach(function(p){
if(typeof p!=='string'){ next.push(p); return; }
var idx = p.indexOf(k);
if(idx===-1){ next.push(p); return; }
found = true;
while(idx!==-1){
if(idx>0) next.push(p.slice(0, idx));
next.push({hl:k});
p = p.slice(idx+k.length);
idx = p.indexOf(k);
}
if(p) next.push(p);
});
parts = next;
});
if(!found) return null;
return parts.map(function(p){ return (typeof p==='string') ? escHtml(p) : '<span style="background:#ffe58a">'+escHtml(p.hl)+'</span>'; }).join('');
}
function applyHighlight(){
var csv = read('hl','');
var kws = csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"], a[href*="space-uid-"], a[href*="uid="]').forEach(function(a){
var orig = a.getAttribute('data-nx-orig');
if(orig===null){ orig = a.textContent||''; a.setAttribute('data-nx-orig', orig); }
if(!kws.length){ a.textContent = orig; return; }
var html = hlHtml(orig, kws);
if(html!==null){ a.innerHTML = html; } else { a.textContent = orig; }
});
}
window.__nxSetHighlight = function(csv){ store('hl', csv||''); applyHighlight(); };
applyHighlight();

// ---------- 18. Quick reply templates ----------
// Inserts text into the reply box ONLY. The user must tap send.
// The reply-box selector is a best-effort fallback chain: the real
// reply box HTML cannot be verified without a logged-in session, so
// if tapping a template does nothing, the selector needs adjusting
// against the live logged-in page.
window.__nxInsertTemplate = function(text){
var box = document.querySelector('#reply_content') || document.querySelector('textarea[name="content"]') || document.querySelector('form textarea') || document.querySelector('textarea');
if(!box){ showToast('未找到回复框，请先点回复'); return false; }
box.focus();
box.value = (box.value ? box.value + '\\n' : '') + text;
box.dispatchEvent(new Event('input', {bubbles:true}));
showToast('已插入模板，点发送即可');
return true;
};

// ---------- 19. Code block copy + basic highlight ----------
function nxFallbackCopy(txt){
var ta = document.createElement('textarea');
ta.value = txt; ta.style.cssText='position:fixed;opacity:0;';
document.body.appendChild(ta); ta.select();
try{ document.execCommand('copy'); showToast('已复制代码'); }catch(e){ showToast('复制失败'); }
ta.remove();
}
function nxCopyCode(txt){
if(navigator.clipboard && navigator.clipboard.writeText){
navigator.clipboard.writeText(txt).then(function(){ showToast('已复制代码'); }, function(){ nxFallbackCopy(txt); });
} else { nxFallbackCopy(txt); }
}
var nxCodeKeywords = {function:1,var:1,let:1,const:1,if:1,else:1,for:1,while:1,return:1,class:1,import:1,export:1,new:1,switch:1,case:1,break:1,continue:1,try:1,catch:1,finally:1,throw:1,typeof:1,instanceof:1,in:1,of:1,do:1,void:1,delete:1,yield:1,await:1,async:1,this:1,super:1,extends:1,static:1,get:1,set:1};
function nxHighlightCode(code){
var out='', i=0, n=code.length;
function esc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
while(i<n){
var two = code.slice(i, i+2);
if(two==='//'){
var eol = code.indexOf('\\n', i);
if(eol===-1) eol = n;
out += '<span style="color:#6a737d">'+esc(code.slice(i, eol))+'</span>';
i = eol; continue;
}
if(two==='/*'){
var end = code.indexOf('*/', i+2);
if(end===-1) end = n; else end += 2;
out += '<span style="color:#6a737d">'+esc(code.slice(i, end))+'</span>';
i = end; continue;
}
var ch = code[i];
if(ch==='"' || ch==="'"){
var j=i+1;
while(j<n){ if(code[j]==='\\\\'){ j+=2; continue; } if(code[j]===ch) break; if(code[j]==='\\n') break; j++; }
if(j<n && code[j]===ch) j++;
out += '<span style="color:#032f62">'+esc(code.slice(i, j))+'</span>';
i = j; continue;
}
if((ch>='a' && ch<='z') || (ch>='A' && ch<='Z') || ch==='_' || ch==='$'){
var k=i+1;
while(k<n){ var c=code[k]; if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c==='_'||c==='$') k++; else break; }
var word = code.slice(i, k);
if(nxCodeKeywords[word]){ out += '<span style="color:#d73a49">'+esc(word)+'</span>'; }
else { out += esc(word); }
i = k; continue;
}
if(ch>='0' && ch<='9'){
var m=i+1;
while(m<n){ var d=code[m]; if((d>='0'&&d<='9')||d==='.') m++; else break; }
out += '<span style="color:#005cc5">'+esc(code.slice(i, m))+'</span>';
i = m; continue;
}
out += esc(ch);
i++;
}
return out;
}
function nxSetupCodeBlocks(){
document.querySelectorAll('pre, .blockcode').forEach(function(el){
if(el.getAttribute('data-nx-code')) return;
el.setAttribute('data-nx-code','1');
if(el.tagName==='PRE' && !el.querySelector('*')){
var raw = el.textContent || '';
el.innerHTML = nxHighlightCode(raw);
}
var btn = document.createElement('button');
btn.textContent='复制';
btn.style.cssText='position:absolute;top:6px;right:6px;padding:3px 10px;border-radius:10px;border:1px solid #bbb;background:rgba(255,255,255,0.9);color:#333;font-size:12px;z-index:5;';
btn.addEventListener('click', function(e){ e.stopPropagation(); nxCopyCode(el.innerText || ''); });
if(window.getComputedStyle(el).position==='static'){ el.style.position='relative'; }
el.appendChild(btn);
});
}
nxSetupCodeBlocks();

// ---------- 20. In-page bilingual translation ----------
// Translation runs ONLY when the user taps translate. Free default is
// MyMemory (no key); an optional BYOK OpenAI-compatible key/base/model
// is set in Settings and stored in UserDefaults on-device only.
window.__nxShowTranslation = function(orig, trans){
var old = document.getElementById('nx-tr-panel'); if(old) old.remove();
var p = document.createElement('div'); p.id='nx-tr-panel';
p.style.cssText='position:fixed;left:12px;right:12px;bottom:90px;max-height:45vh;overflow:auto;background:#fff;color:#111;border-radius:14px;padding:14px;z-index:999999;box-shadow:0 4px 24px rgba(0,0,0,0.3);font-size:15px;line-height:1.6;';
var o = document.createElement('div'); o.textContent = orig; p.appendChild(o);
var t = document.createElement('div'); t.textContent = trans; t.style.cssText='color:#2563eb;margin-top:8px;'; p.appendChild(t);
var c = document.createElement('button'); c.textContent='关闭'; c.style.cssText='margin-top:10px;padding:6px 16px;border-radius:12px;border:1px solid #ccc;background:#f2f2f2;font-size:14px;'; c.addEventListener('click', function(){ p.remove(); }); p.appendChild(c);
document.body.appendChild(p);
};
window.__nxCollectTranslatable = function(){
var out = [];
var title = document.querySelector('#thread_subject');
if(title){ title.setAttribute('data-nx-trid','title'); out.push({id:'title', text:(title.textContent||'').trim()}); }
document.querySelectorAll('.t_f').forEach(function(el, i){
var s=(el.innerText||'').trim();
if(!s) return;
el.setAttribute('data-nx-trid', 'p'+i);
out.push({id:'p'+i, text:s.slice(0, 2500)});
});
return JSON.stringify(out);
};
window.__nxApplyTranslations = function(json){
var arr = []; try{ arr = JSON.parse(json); }catch(e){ return; }
arr.forEach(function(it){
var el = document.querySelector('[data-nx-trid="'+it.id+'"]');
if(!el || !el.parentNode) return;
var old = el.parentNode.querySelector('[data-nx-tr="'+it.id+'"]');
if(old) old.remove();
var d = document.createElement('div');
d.setAttribute('data-nx-tr', it.id);
d.textContent = it.trans;
d.style.cssText='color:#2563eb;background:#eff6ff;border-radius:8px;padding:8px 10px;margin:6px 0;font-size:15px;line-height:1.6;';
el.parentNode.insertBefore(d, el.nextSibling);
});
};
window.__nxClearTranslation = function(){
document.querySelectorAll('[data-nx-tr]').forEach(function(d){ d.remove(); });
var p = document.getElementById('nx-tr-panel'); if(p) p.remove();
};
})();
"""

// MARK: - Model
final class BrowserModel: NSObject, ObservableObject {
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

override init() {
super.init()
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
webView?.evaluateJavaScript("window.__nxSetDark && window.__nxSetDark(\(on ? "true" : "false"));", completionHandler: nil)
}
func setFontScale(_ s: CGFloat) {
fontScale = s
UserDefaults.standard.set(Double(s), forKey: "nx_fontScale")
webView?.pageZoom = s
}
func setHideAds(_ on: Bool) {
hideAds = on
UserDefaults.standard.set(on, forKey: "nx_hideAds")
webView?.evaluateJavaScript("window.__nxSetHideAds && window.__nxSetHideAds(\(on ? "true" : "false"));", completionHandler: nil)
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

// MARK: - v2 batch B: safe features (read-only or user-triggered)
// Translation config lives in UserDefaults on-device only (NOT
// localStorage, NOT the repo). The BYOK key never leaves the device
// except in the Authorization header of the user's own API calls.
@Published var userNotesText = ""
@Published var blockedText = ""
@Published var highlightText = ""
@Published var templatesText = ""
@Published var templates: [String] = []
@Published var searchHistory: [String] = []
@Published var trKey = ""
@Published var trBase = "https://openrouter.ai/api/v1"
@Published var trModel = "deepseek-chat"

func restoreBatchBSettings() {
userNotesText = UserDefaults.standard.string(forKey: "nx_notesText") ?? ""
blockedText = UserDefaults.standard.string(forKey: "nx_blockedText") ?? ""
highlightText = UserDefaults.standard.string(forKey: "nx_hlText") ?? ""
setTemplatesText(UserDefaults.standard.string(forKey: "nx_templatesText") ?? "")
searchHistory = UserDefaults.standard.stringArray(forKey: "nx_searchHist") ?? []
loadTrConfig()
}

func setUserNotesText(_ s: String) {
userNotesText = s
UserDefaults.standard.set(s, forKey: "nx_notesText")
var dict: [String: String] = [:]
s.split(separator: "\n").forEach { line in
let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
if parts.count == 2, !parts[0].isEmpty { dict[parts[0]] = parts[1] }
}
let json = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
let esc = json.replacingOccurrences(of: "'", with: "\\'")
webView?.evaluateJavaScript("window.__nxSetNotes && window.__nxSetNotes('\(esc)');", completionHandler: nil)
}

func setBlockedText(_ s: String) {
blockedText = s
UserDefaults.standard.set(s, forKey: "nx_blockedText")
let names = s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let json = (try? JSONSerialization.data(withJSONObject: names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
let esc = json.replacingOccurrences(of: "'", with: "\\'")
webView?.evaluateJavaScript("window.__nxSetBlocked && window.__nxSetBlocked('\(esc)');", completionHandler: nil)
}

func setHighlightText(_ s: String) {
highlightText = s
UserDefaults.standard.set(s, forKey: "nx_hlText")
let esc = s.replacingOccurrences(of: "'", with: "\\'")
webView?.evaluateJavaScript("window.__nxSetHighlight && window.__nxSetHighlight('\(esc)');", completionHandler: nil)
}

func setTemplatesText(_ s: String) {
templatesText = s
UserDefaults.standard.set(s, forKey: "nx_templatesText")
templates = s.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func insertTemplate(_ t: String) {
let esc = t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
webView?.evaluateJavaScript("window.__nxInsertTemplate && window.__nxInsertTemplate('\(esc)');", completionHandler: nil)
}

func search(_ q: String) {
let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
guard !query.isEmpty else { return }
var hist = searchHistory
hist.removeAll { $0 == query }
hist.insert(query, at: 0)
if hist.count > 10 { hist = Array(hist.prefix(10)) }
searchHistory = hist
UserDefaults.standard.set(hist, forKey: "nx_searchHist")
let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
if let url = URL(string: "https://forum.naixi.net/search.php?mod=forum&srchtxt=\(enc)&searchsubmit=yes") {
load(url)
}
}

func goSearchPage() {
if let url = URL(string: "https://forum.naixi.net/search.php?mod=forum") { load(url) }
}

func shareCurrentPage() {
let title = webView?.title ?? ""
let url = webView?.url
var items: [Any] = []
if !title.isEmpty { items.append(title) }
if let url = url { items.append(url) }
if items.isEmpty { return }
presentShare(items: items)
}

// MARK: - v2 batch B: in-page bilingual translation
func saveTrConfig() {
UserDefaults.standard.set(trKey, forKey: "nx_trKey")
UserDefaults.standard.set(trBase, forKey: "nx_trBase")
UserDefaults.standard.set(trModel, forKey: "nx_trModel")
}

func loadTrConfig() {
trKey = UserDefaults.standard.string(forKey: "nx_trKey") ?? ""
trBase = UserDefaults.standard.string(forKey: "nx_trBase") ?? "https://openrouter.ai/api/v1"
trModel = UserDefaults.standard.string(forKey: "nx_trModel") ?? "deepseek-chat"
}

private func containsCJK(_ s: String) -> Bool {
s.unicodeScalars.contains { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || ($0.value >= 0x3400 && $0.value <= 0x4DBF) }
}

private func splitForTranslate(_ text: String, maxBytes: Int) -> [String] {
var chunks: [String] = []
var current = ""
for para in text.components(separatedBy: "\n") {
let add = current.isEmpty ? para : "\n" + para
if (current + add).utf8.count > maxBytes {
if !current.isEmpty { chunks.append(current); current = "" }
var rest = para
while rest.utf8.count > maxBytes {
let cut = rest.prefix(maxBytes / 3)
chunks.append(String(cut))
rest = String(rest.dropFirst(cut.count))
}
current = rest
} else {
current += add
}
}
if !current.isEmpty { chunks.append(current) }
return chunks
}

private func translateChunk(_ text: String, completion: @escaping (String?) -> Void) {
if !trKey.isEmpty {
translateBYOK(text, completion: completion)
} else {
translateMyMemory(text, completion: completion)
}
}

private func translateMyMemory(_ text: String, completion: @escaping (String?) -> Void) {
let pair = containsCJK(text) ? "zh-CN|en" : "en|zh-CN"
guard let enc = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
let url = URL(string: "https://api.mymemory.translated.net/get?q=\(enc)&langpair=\(pair)") else {
completion(nil); return
}
URLSession.shared.dataTask(with: url) { data, _, _ in
guard let data = data,
let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
let resp = obj["responseData"] as? [String: Any],
let out = resp["translatedText"] as? String else {
completion(nil); return
}
completion(out)
}.resume()
}

private func translateBYOK(_ text: String, completion: @escaping (String?) -> Void) {
let base = trBase.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
guard let url = URL(string: base + "/chat/completions") else { completion(nil); return }
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("Bearer \(trKey)", forHTTPHeaderField: "Authorization")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
let body: [String: Any] = [
"model": trModel,
"messages": [
["role": "system", "content": "Translate the following text. Return only the translation, no explanation."],
["role": "user", "content": text]
]
]
req.httpBody = try? JSONSerialization.data(withJSONObject: body)
URLSession.shared.dataTask(with: req) { data, _, _ in
guard let data = data,
let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
let choices = obj["choices"] as? [[String: Any]],
let msg = choices.first?["message"] as? [String: Any],
let out = msg["content"] as? String else {
completion(nil); return
}
completion(out.trimmingCharacters(in: .whitespacesAndNewlines))
}.resume()
}

private func translateChunks(_ chunks: [String], index: Int, acc: [String], completion: @escaping (String?) -> Void) {
if index >= chunks.count { completion(acc.joined(separator: "\n")); return }
translateChunk(chunks[index]) { out in
guard let out = out else { completion(nil); return }
var next = acc
next.append(out)
self.translateChunks(chunks, index: index + 1, acc: next, completion: completion)
}
}

private func translateBlocks(_ items: [[String: String]], index: Int, acc: [[String: String]], completion: @escaping ([[String: String]]) -> Void) {
if index >= items.count { completion(acc); return }
let it = items[index]
let chunks = splitForTranslate(it["text"] ?? "", maxBytes: trKey.isEmpty ? 450 : 8000)
translateChunks(chunks, index: 0, acc: []) { translated in
var next = acc
if let translated = translated {
next.append(["id": it["id"] ?? "", "trans": translated])
}
self.translateBlocks(items, index: index + 1, acc: next, completion: completion)
}
}

func translateSelection() {
webView?.evaluateJavaScript("window.getSelection ? (window.getSelection().toString()||'') : ''") { result, _ in
let text = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('请先在页面里选中要翻译的文字');", completionHandler: nil)
return
}
let chunks = self.splitForTranslate(text, maxBytes: self.trKey.isEmpty ? 450 : 8000)
self.translateChunks(chunks, index: 0, acc: []) { translated in
guard let translated = translated else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('翻译失败，请稍后再试');", completionHandler: nil)
return
}
let escO = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
let escT = translated.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
self.webView?.evaluateJavaScript("window.__nxShowTranslation && window.__nxShowTranslation('\(escO)', '\(escT)');", completionHandler: nil)
}
}
}

func translatePage() {
webView?.evaluateJavaScript("window.__nxCollectTranslatable && window.__nxCollectTranslatable();") { result, _ in
guard let json = result as? String,
let data = json.data(using: .utf8),
let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]], !items.isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('当前页没有可翻译的正文');", completionHandler: nil)
return
}
let limit = self.trKey.isEmpty ? 2500 : 8000
var total = 0
var picked: [[String: String]] = []
for it in items {
let n = (it["text"] ?? "").count
if total + n > limit, !picked.isEmpty { break }
total += n
picked.append(it)
}
self.translateBlocks(picked, index: 0, acc: []) { results in
guard !results.isEmpty else {
self.webView?.evaluateJavaScript("window.__nxToast && window.__nxToast('翻译失败，请稍后再试');", completionHandler: nil)
return
}
let data = (try? JSONSerialization.data(withJSONObject: results)) ?? Data()
let json = String(data: data, encoding: .utf8) ?? "[]"
let esc = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
self.webView?.evaluateJavaScript("window.__nxApplyTranslations && window.__nxApplyTranslations('\(esc)');", completionHandler: nil)
}
}
}

func clearTranslation() {
webView?.evaluateJavaScript("window.__nxClearTranslation && window.__nxClearTranslation();", completionHandler: nil)
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
model.hideAds = UserDefaults.standard.object(forKey: "nx_hideAds") as? Bool ?? true
model.keywords = UserDefaults.standard.string(forKey: "nx_keywords") ?? ""
let fs = UserDefaults.standard.double(forKey: "nx_fontScale")
if fs > 0 { model.fontScale = CGFloat(fs)}
model.infiniteScroll = UserDefaults.standard.object(forKey: "nx_infinite") as? Bool ?? true
model.foldLongPosts = UserDefaults.standard.object(forKey: "nx_fold") as? Bool ?? true
model.restoreBatchBSettings()
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
webView.scrollView.contentInsetAdjustmentBehavior = .always
// leave room so the last line is never hidden behind the bottom bar
webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
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
if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
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
BarButton(icon: model.isDark ? "moon.fill" : "moon", label: "深色") {
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
@State private var searchText = ""

let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

var body: some View {
NavigationStack {
ScrollView {
VStack(alignment: .leading, spacing: 10) {
TextField("搜索帖子…", text: $searchText)
.textFieldStyle(.roundedBorder)
.submitLabel(.search)
.onSubmit {
if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
model.search(searchText)
dismiss()
}
}
if !model.searchHistory.isEmpty {
ScrollView(.horizontal, showsIndicators: false) {
HStack(spacing: 8) {
ForEach(model.searchHistory, id: \.self) { h in
Button(h) {
model.search(h)
dismiss()
}
.font(.system(size: 13))
.padding(.horizontal, 10)
.padding(.vertical, 6)
.background(Color(.secondarySystemBackground), in: Capsule())
.buttonStyle(.plain)
}
}
}
}
Button("站内搜索页") { model.goSearchPage(); dismiss() }
.font(.system(size: 13))
.foregroundStyle(.secondary)
}
.padding(.horizontal, 16)
.padding(.top, 12)
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
@State private var notesText = ""
@State private var blockedText = ""
@State private var highlightText = ""
@State private var templatesText = ""
@State private var trKey = ""
@State private var trBase = ""
@State private var trModel = ""

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
Menu("插入回复模板") {
if model.templates.isEmpty {
Text("没有模板，先在下方添加")
} else {
ForEach(model.templates, id: \.self) { t in
Button(t) { model.insertTemplate(t); dismiss() }
}
}
}
Button("翻译选中文字") { model.translateSelection(); dismiss() }
Button("翻译本页（双语对照）") { model.translatePage(); dismiss() }
Button("清除翻译") { model.clearTranslation(); dismiss() }
Button("分享当前页") { model.shareCurrentPage() }
}
Section("用户备注与黑名单") {
Text("备注格式：用户名=备注，每行一个；帖子页用户名旁会显示小黄条。黑名单每行一个用户名，列表和回复里都会隐藏。")
.font(.footnote)
.foregroundStyle(.secondary)
TextEditor(text: $notesText)
.frame(minHeight: 70)
.onChange(of: notesText) { v in model.setUserNotesText(v) }
Text("黑名单（每行一个用户名）")
.font(.footnote)
.foregroundStyle(.secondary)
TextEditor(text: $blockedText)
.frame(minHeight: 70)
.onChange(of: blockedText) { v in model.setBlockedText(v) }
}
Section("关键词高亮") {
TextField("多个关键词用英文逗号隔开", text: $highlightText)
.onChange(of: highlightText) { v in model.setHighlightText(v) }
HStack {
Button("复制导出") { UIPasteboard.general.string = highlightText }
Button("从剪贴板导入") {
if let s = UIPasteboard.general.string {
highlightText = s
model.setHighlightText(s)
}
}
}
Text("和屏蔽词分开两组。命中的标题和用户名会标黄。")
.font(.footnote)
.foregroundStyle(.secondary)
}
Section("快捷回复模板") {
TextEditor(text: $templatesText)
.frame(minHeight: 90)
.onChange(of: templatesText) { v in model.setTemplatesText(v) }
Text("每行一条模板。在帖子页点「插入回复模板」选一条插进回复框，发送要自己点。")
.font(.footnote)
.foregroundStyle(.secondary)
}
Section("翻译设置") {
SecureField("BYOK Key（可选，留空用免费接口）", text: $trKey)
.onChange(of: trKey) { _ in model.trKey = trKey; model.saveTrConfig() }
TextField("Base URL", text: $trBase)
.autocapitalization(.none)
.disableAutocorrection(true)
.onChange(of: trBase) { _ in model.trBase = trBase; model.saveTrConfig() }
TextField("模型", text: $trModel)
.autocapitalization(.none)
.disableAutocorrection(true)
.onChange(of: trModel) { _ in model.trModel = trModel; model.saveTrConfig() }
Text("默认免费 MyMemory 接口（无需 key，每页上限 2500 字）；填了 Key 后走你自己的 OpenAI 兼容接口（每页上限 8000 字）。Key 只存在本机，不进代码仓库。")
.font(.footnote)
.foregroundStyle(.secondary)
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
.onAppear {
keywordsText = model.keywords
notesText = model.userNotesText
blockedText = model.blockedText
highlightText = model.highlightText
templatesText = model.templatesText
trKey = model.trKey
trBase = model.trBase
trModel = model.trModel
}
}
.presentationDetents([.medium,.large])
}
}
