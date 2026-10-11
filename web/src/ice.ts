export function iceConfiguration(value:unknown):RTCConfiguration {
  if(value===undefined)return {iceServers:[],bundlePolicy:'max-bundle'};
  const c=value as {iceServers:RTCIceServer[];iceTransportPolicy:RTCIceTransportPolicy;expiresAt:number}|null;
  const now=Date.now()/1000;
  if(!c||!Number.isFinite(c.expiresAt)||c.expiresAt<=now||c.expiresAt>now+7200||
    !['all','relay'].includes(c.iceTransportPolicy)||!Array.isArray(c.iceServers)||c.iceServers.length<1||c.iceServers.length>4||
    !c.iceServers.every(s=>s&&Array.isArray(s.urls)&&s.urls.length>0&&s.urls.length<=4&&
      typeof s.username==='string'&&s.username.length>0&&s.username.length<=512&&
      typeof s.credential==='string'&&s.credential.length>0&&s.credential.length<=512&&
      s.urls.every(url=>{
        if(typeof url!=='string'||url.length>512||!/^turns?:/.test(url))return false;
        try {const u=new URL(url.replace(':','://'));return !!u.hostname&&!u.username&&!u.password&&!u.pathname&&!u.hash&&['','?transport=udp','?transport=tcp'].includes(u.search);}
        catch{return false;}
      })))throw new Error('Сервер передал недействительные параметры подключения');
  return {iceServers:c.iceServers,iceTransportPolicy:c.iceTransportPolicy,bundlePolicy:'max-bundle'};
}
