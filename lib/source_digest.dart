// SHA-256 for deterministic source binding, not signatures or authentication.
// No external package or global state; input bytes are not retained.
import 'dart:typed_data';

Uint8List sourceSha256(List<int> input) {
  const mask = 0xffffffff;
  const k = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
  ];
  var hash = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  final bytes = Uint8List(((input.length + 9 + 63) ~/ 64) * 64);
  bytes.setRange(0,input.length,input);
  bytes[input.length] = 0x80;
  var bits = input.length * 8;
  for(var i=0;i<8;i++){bytes[bytes.length-1-i]=bits&255;bits=bits>>>8;}
  int rotate(int v,int n) => ((v>>>n)|(v<<(32-n)))&mask;
  final w = Uint32List(64);
  for(var offset=0;offset<bytes.length;offset+=64){
    for(var i=0;i<16;i++){final p=offset+i*4;w[i]=(bytes[p]<<24)|(bytes[p+1]<<16)|(bytes[p+2]<<8)|bytes[p+3];}
    for(var i=16;i<64;i++){
      final a=w[i-15], b=w[i-2];
      final s0=rotate(a,7)^rotate(a,18)^(a>>>3),s1=rotate(b,17)^rotate(b,19)^(b>>>10);
      w[i]=(w[i-16]+s0+w[i-7]+s1)&mask;
    }
    var a=hash[0],b=hash[1],c=hash[2],d=hash[3],e=hash[4],f=hash[5],g=hash[6],h=hash[7];
    for(var i=0;i<64;i++){
      final s1=rotate(e,6)^rotate(e,11)^rotate(e,25),choose=(e&f)^((~e)&g);
      final t1=(h+s1+choose+k[i]+w[i])&mask;
      final s0=rotate(a,2)^rotate(a,13)^rotate(a,22), majority=(a&b)^(a&c)^(b&c);
      final t2=(s0+majority)&mask;
      h=g;g=f;f=e;e=(d+t1)&mask;d=c;c=b;b=a;a=(t1+t2)&mask;
    }
    final next=[a,b,c,d,e,f,g,h];
    hash=[for(var i=0;i<8;i++) (hash[i]+next[i])&mask];
  }
  final result=Uint8List(32);
  for(var i=0;i<8;i++){for(var j=0;j<4;j++){result[i*4+j]=(hash[i]>>>(24-j*8))&255;}}
  // Best effort scratch overwrite. Dart cannot promise zeroization of all copies.
  bytes.fillRange(0,bytes.length,0);w.fillRange(0,w.length,0);
  return result;
}
