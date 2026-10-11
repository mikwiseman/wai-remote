const encoder = new TextEncoder();
export function bytes(text: string) { return encoder.encode(text); }
export function b64(data: ArrayBuffer | Uint8Array) {
  const array = data instanceof Uint8Array ? data : new Uint8Array(data);
  let text = ''; for (const byte of array) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function unb64(text: string): Uint8Array<ArrayBuffer> {
  if (text.length > 180000 || !/^[A-Za-z0-9_-]*$/.test(text)) throw new Error('Некорректный ключ');
  return Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
}
export async function keyID(publicKey: string) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', unb64(publicKey)))].map(x => x.toString(16).padStart(2,'0')).join('');
}
export interface Identity { privateKey: CryptoKey; publicKey: string; id: string }
export async function identity(): Promise<Identity> {
  if (!isSecureContext || !crypto.subtle) throw new Error('Для подключения нужен HTTPS или localhost.');
  const db = await new Promise<IDBDatabase>((resolve,reject) => {
    const r = indexedDB.open('wai-remote-identity',1);
    r.onupgradeneeded = () => r.result.createObjectStore('keys'); r.onsuccess=()=>resolve(r.result); r.onerror=()=>reject(r.error);
  });
  try {
    const saved = await new Promise<Identity | undefined>((resolve,reject)=> {
      const r=db.transaction('keys').objectStore('keys').get('viewer'); r.onsuccess=()=>resolve(r.result); r.onerror=()=>reject(r.error);
    });
    if(saved) return saved;
    const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
    const publicKey=b64(await crypto.subtle.exportKey('raw',pair.publicKey));
    const result={privateKey:pair.privateKey,publicKey,id:await keyID(publicKey)};
    await new Promise<void>((resolve,reject)=> {
      const tx=db.transaction('keys','readwrite'); tx.objectStore('keys').put(result,'viewer'); tx.oncomplete=()=>resolve(); tx.onerror=()=>reject(tx.error);
    }); return result;
  } finally { db.close(); }
}
export async function sign(identity: Identity, domain: string, payload: Uint8Array<ArrayBuffer>) {
  const prefix=bytes(domain+'\0'); const data=new Uint8Array(prefix.length+payload.length); data.set(prefix);data.set(payload,prefix.length);
  return b64(await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},identity.privateKey,data));
}
export async function verify(publicKey: string, domain: string, payload: Uint8Array<ArrayBuffer>, signature: string) {
  const key=await crypto.subtle.importKey('raw',unb64(publicKey),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  const prefix=bytes(domain+'\0');const data=new Uint8Array(prefix.length+payload.length);data.set(prefix);data.set(payload,prefix.length);
  return crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,unb64(signature),data);
}
export async function proof(secret: string, payload: Uint8Array<ArrayBuffer>) {
  const key=await crypto.subtle.importKey('raw',unb64(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const prefix=bytes('wai-remote/pair/v1\0');const data=new Uint8Array(prefix.length+payload.length);data.set(prefix);data.set(payload,prefix.length);
  return b64(await crypto.subtle.sign('HMAC',key,data));
}
