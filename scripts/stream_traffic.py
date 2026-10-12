"""Independent packet traffic reference; imports do not modify numerical vectors."""
def traffic(m,n,k,rows,cols,tile,group,bus_bytes,scale_once):
    w=a=s=beats=packets=0
    for mt in range(0,m,rows):
        ml=min(rows,m-mt)
        for nt in range(0,n,cols):
            nl=min(cols,n-nt);q=0
            while q<k:
                length=min(tile,k-q,group-q%group)
                wb=(q%2+length+1)//2
                w+=nl*wb;a+=ml*length
                beats+=nl*((wb+bus_bytes-1)//bus_bytes)+ml*((length+bus_bytes-1)//bus_bytes)
                if not scale_once or q+length==k or (q+length)%group==0:
                    s+=2*(ml+nl)
                    beats+=(2*ml+bus_bytes-1)//bus_bytes+(2*nl+bus_bytes-1)//bus_bytes
                packets+=1;q+=length
    return dict(weight_bytes=w,activation_bytes=a,scale_bytes=s,input_beats=beats,
                padding_bytes=beats*bus_bytes-w-a-s,valid_macs=m*n*k,
                compute_cycles=((m+rows-1)//rows)*((n+cols-1)//cols)*k,tiles=packets)
