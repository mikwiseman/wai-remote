import jsQR from 'jsqr';

/** Camera frames and selected images stay on this device. */
export function installQRScanner(validate: (text:string)=>Promise<string|undefined>, onInvitation:(text:string)=>void) {
  const dialog=document.createElement('dialog');
  dialog.className='qr-dialog';
  dialog.setAttribute('aria-labelledby','qrTitle');
  dialog.innerHTML=`<div class="qr-heading"><h2 id="qrTitle">Подключиться по QR-коду</h2><button type="button" class="qr-close" aria-label="Закрыть сканер">Закрыть</button></div>
    <video class="qr-camera" autoplay muted playsinline aria-hidden="true"></video>
    <p class="qr-status" role="status">Наведите камеру на QR-код в WAI Remote.</p>
    <button type="button" class="qr-file">Открыть изображение QR-кода</button><input type="file" accept="image/*" hidden>
    <p class="qr-note">Новое устройство подключится после разрешения владельца Mac.</p>`;
  document.body.append(dialog);
  const video=dialog.querySelector('video')!, message=dialog.querySelector('.qr-status')!;
  const file=dialog.querySelector('input')!;
  const canvas=document.createElement('canvas'), context=canvas.getContext('2d',{willReadFrequently:true})!;
  let stream:MediaStream|undefined,timer:number|undefined,generation=0,readingGeneration:number|undefined;

  function stopCamera(){clearInterval(timer);timer=undefined;stream?.getTracks().forEach(track=>track.stop());stream=undefined;video.srcObject=null;}
  function close(){generation++;stopCamera();dialog.close();file.value='';}
  dialog.querySelector('button')!.addEventListener('click',close);
  dialog.querySelector('.qr-file')!.addEventListener('click',()=>file.click());
  dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  document.addEventListener('visibilitychange',()=>{if(document.hidden&&dialog.open)close();});

  async function read(source:CanvasImageSource,width:number,height:number,token:number,maxSize:number){
    if(readingGeneration===token||!width||!height||token!==generation||!dialog.open)return;
    readingGeneration=token;
    try{
      const scale=Math.min(1,maxSize/Math.max(width,height));
      canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));
      context.drawImage(source,0,0,canvas.width,canvas.height);
      const image=context.getImageData(0,0,canvas.width,canvas.height);
      const code=jsQR(image.data,image.width,image.height);
      if(!code)return false;
      const invitation=await validate(code.data);
      if(token!==generation||!dialog.open)return;
      if(invitation){close();onInvitation(invitation);return true;}
      message.textContent='Это не приглашение WAI Remote. Покажите другой QR-код.';
      return false;
    }finally{if(readingGeneration===token)readingGeneration=undefined;}
  }

  file.addEventListener('change',async()=>{
    const selected=file.files?.[0];if(!selected)return;
    stopCamera();const token=++generation;
    message.textContent='Читаем QR-код…';
    try{
      if(selected.size>20_000_000)throw new Error('large image');
      const image=await createImageBitmap(selected);
      try{
        const accepted=await read(image,image.width,image.height,token,2400);
        if(!accepted&&token===generation&&dialog.open)message.textContent='На изображении нет приглашения WAI Remote. Выберите другое изображение.';
      }finally{image.close();}
    }catch{if(token===generation)message.textContent='Не удалось прочитать изображение. Выберите другое изображение QR-кода.';}
    file.value='';
  });

  return async()=>{
    if(dialog.open)return;
    const token=++generation;dialog.showModal();
    message.textContent='Наведите камеру на QR-код в WAI Remote.';
    try{
      const acquired=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'},width:{ideal:1280}},audio:false});
      if(token!==generation||!dialog.open){acquired.getTracks().forEach(track=>track.stop());return;}
      stream=acquired;video.srcObject=stream;await video.play();
      if(token!==generation||!dialog.open)return;
      timer=window.setInterval(()=>{if(video.readyState>=2)void read(video,video.videoWidth,video.videoHeight,token,1280);},150);
    }catch{
      if(token===generation){stopCamera();message.textContent='Камера недоступна. Разрешите её в браузере или откройте изображение QR-кода.';}
    }
  };
}
