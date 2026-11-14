import sys,os,glob
import numpy as np
from PIL import Image, ImageFilter
def lin(c):
    c=c/255.0
    return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def lum(a): return 0.2126*lin(a[...,0])+0.7152*lin(a[...,1])+0.0722*lin(a[...,2])
def measure(path, box):
    im=Image.open(path).convert('RGB'); w,h=im.size
    x0,y0,x1,y1=[int(v) for v in (box[0]*w,box[1]*h,box[2]*w,box[3]*h)]
    cr=im.crop((x0,y0,x1,y1)); a=np.asarray(cr).astype(float)
    L=lum(a)
    # text: near-white pixels (all channels >= 200 and low chroma)
    mx=a.max(-1); mn=a.min(-1)
    mask=(mn>=243)&((mx-mn)<=14)
    if mask.sum()<30: return None
    m=Image.fromarray((mask*255).astype('uint8'))
    d3=np.asarray(m.filter(ImageFilter.MaxFilter(7)))>0     # within 3 px
    d1=np.asarray(m.filter(ImageFilter.MaxFilter(3)))>0     # within 1 px
    ring=d3&~d1&~mask
    if ring.sum()<30: return None
    t=np.median(L[mask]); 
    r_med=np.median(L[ring]); r_p75=np.percentile(L[ring],75); r_p90=np.percentile(L[ring],90)
    return dict(text=t, ring_med=r_med, ring_p75=r_p75, c_med=(t+0.05)/(r_med+0.05), c_p75=(t+0.05)/(r_p75+0.05), c_p90=(t+0.05)/(r_p90+0.05), n=int(mask.sum()))
if __name__=='__main__':
    box=(0.15,0.0,0.85,0.075)
    for f in sys.argv[1:]:
        r=measure(f,box)
        print(os.path.basename(f), 'n/a' if r is None else ' '.join('%s=%.2f'%(k,v) if k!='n' else 'n=%d'%v for k,v in r.items()))

def plate(path, box=(0.15,0.0,0.85,0.075)):
    im=Image.open(path).convert('RGB'); w,h=im.size
    x0,y0,x1,y1=[int(v) for v in (box[0]*w,box[1]*h,box[2]*w,box[3]*h)]
    a=np.asarray(im.crop((x0,y0,x1,y1))).astype(float); L=lum(a)
    # the plate is the area of the bar: find the rows/cols that differ from the scene (corner pixel)
    ref=L[2,2]
    diff=np.abs(L-ref)>0.01
    rows=np.where(diff.sum(1)>20)[0]; cols=np.where(diff.sum(0)>5)[0]
    if len(rows)==0: return None
    r0,r1,c0,c1=rows[0],rows[-1],cols[0],cols[-1]
    inner=L[r0+3:r1-2, c0+8:c1-8]
    mx=a.max(-1)[r0+3:r1-2, c0+8:c1-8]; mn=a.min(-1)[r0+3:r1-2, c0+8:c1-8]
    nottext=~((mn>=150))
    return dict(scene=ref, plate_med=float(np.median(inner[nottext])), plate_p10=float(np.percentile(inner[nottext],10)), plate_p90=float(np.percentile(inner[nottext],90)))
if __name__=='__main__' and len(sys.argv)>1:
    print('--- plate luminance (relative, 0 black .. 1 white)')
    for f in sys.argv[1:]:
        print(os.path.basename(f), plate(f))

def plate_contrast(path, box=(0.15,0.0,0.85,0.075)):
    """white text against the plate itself (3 px around each glyph left out, that is the halo's)"""
    im=Image.open(path).convert('RGB'); w,h=im.size
    x0,y0,x1,y1=[int(v) for v in (box[0]*w,box[1]*h,box[2]*w,box[3]*h)]
    a=np.asarray(im.crop((x0,y0,x1,y1))).astype(float); L=lum(a)
    mx=a.max(-1); mn=a.min(-1)
    mask=(mn>=243)&((mx-mn)<=14)
    ref=L[2,2]; diff=np.abs(L-ref)>0.01
    rows=np.where(diff.sum(1)>20)[0]; cols=np.where(diff.sum(0)>5)[0]
    if len(rows)==0 or mask.sum()<30: return None
    r0,r1,c0,c1=rows[0]+3,rows[-1]-2,cols[0]+8,cols[-1]-8
    m=Image.fromarray((mask*255).astype('uint8'))
    d3=np.asarray(m.filter(ImageFilter.MaxFilter(9)))>0
    region=np.zeros_like(mask); region[r0:r1,c0:c1]=True
    plate=region&~d3
    t=np.median(L[mask])
    p50=np.median(L[plate]); p90=np.percentile(L[plate],90)
    return dict(plate_p50=round(float(p50),3), plate_p90=round(float(p90),3), c_p50=round((t+0.05)/(p50+0.05),2), c_p90=round((t+0.05)/(p90+0.05),2))
if __name__=='__main__' and len(sys.argv)>1:
    print('--- white text vs plate (no halo)')
    for f in sys.argv[1:]:
        print(os.path.basename(f), plate_contrast(f))
