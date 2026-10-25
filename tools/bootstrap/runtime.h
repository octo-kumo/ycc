/* Runtime support for generated GNU99 C. Compiler logic is generated from Y. */
#include "yv.h"
#include "host.h"
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static ylong cg_host_machine(void) {
#ifdef __aarch64__
    return 183;
#else
    return 62;
#endif
}

static inline Yv *cg_long(ylong n) {
    return yv_fits_immediate(n) ? yv_immediate(n) : yv_long(n);
}
#define yv_long cg_long
#define cg_literal_long(n) (__extension__({static Yv cg_literal={.tag=Y_LONG,.u={.l=(n)}};yv_fits_immediate(n)?yv_immediate(n):&cg_literal;}))

// Keep primitive access in generated C visible to GCC without LTO.
static inline ylong cg_unbox_long(const Yv *v) { return yv_long_value(v); }
#define yv_l cg_unbox_long

// Each typed field site usually sees one record shape. Validate the hint so
// unions, maps, spreads and records grown after construction remain correct.
static Yv *cg_field_get(const Yv *v,const char *key,size_t *hint) {
    if(!v || yv_tag(v)!=Y_REC)return yv_none();
    size_t at=*hint;
    if(at<v->u.r.len && (v->u.r.keys[at]==key || !strcmp(v->u.r.keys[at],key)))return v->u.r.vals[at];
    for(at=0;at<v->u.r.len;++at) {
        if(v->u.r.keys[at]==key || !strcmp(v->u.r.keys[at],key)) {
            *hint=at;return v->u.r.vals[at];
        }
    }
    return yv_none();
}
#define cg_field(v,key) (__extension__({static size_t cg_hint;cg_field_get((v),(key),&cg_hint);}))

static Yv *cg_record(size_t n,char *const *keys,Yv **values) {
    Yv *v=malloc(sizeof(*v)+n*sizeof(Yv *));
    if(!v)exit(1);
    v->tag=Y_REC;v->u.r.keys=(char **)keys;v->u.r.vals=(Yv **)(v+1);
    v->u.r.len=v->u.r.cap=n;
    if(n)memcpy(v->u.r.vals,values,n*sizeof(Yv *));
    return v;
}

typedef Yv *(*CgCode)(Yv *, size_t, Yv **);
typedef struct { CgCode code; struct CgEnv *env; size_t arity; } CgClosure;
typedef struct { const char *name; Yv *value; } CgBinding;
typedef struct CgEnv { struct CgEnv *parent; size_t len, cap, refs; CgBinding *bindings; } CgEnv;
static size_t cg_hash(const char *name) {
    size_t h=1469598103934665603ULL;
    for(const unsigned char *p=(const unsigned char *)name;*p;++p)h=(h^*p)*1099511628211ULL;
    return h;
}
static CgBinding *cg_binding(CgEnv *e,const char *name) {
    size_t at=cg_hash(name)&(e->cap-1);
    while(e->bindings[at].name && strcmp(e->bindings[at].name,name))at=(at+1)&(e->cap-1);
    return e->bindings+at;
}
static CgEnv *cg_scope(CgEnv *parent) {
    CgEnv *e=calloc(1,sizeof(*e));if(!e){fputs("bootstrap: out of memory\n",stderr);exit(1);}
    e->parent=parent;e->refs=1;if(parent)++parent->refs;
    e->cap=8;e->bindings=calloc(e->cap,sizeof(*e->bindings));if(!e->bindings)exit(1);
    return e;
}
static void cg_env_drop(CgEnv **slot) {
    CgEnv *e=*slot;
    while(e && --e->refs==0){CgEnv *parent=e->parent;free(e->bindings);free(e);e=parent;}
}
static Yv *cg_define(CgEnv *env,const char *name,Yv *v) {
    CgEnv *e=env;
    if((e->len+1)*2>=e->cap) {
        CgBinding *old=e->bindings;size_t cap=e->cap;e->cap*=2;
        e->bindings=calloc(e->cap,sizeof(*e->bindings));if(!e->bindings)exit(1);
        for(size_t i=0;i<cap;++i)if(old[i].name)*cg_binding(e,old[i].name)=old[i];
        free(old);
    }
    CgBinding *b=cg_binding(e,name);if(!b->name){b->name=name;++e->len;}b->value=v;return v;
}
static Yv *cg_get(CgEnv *env,const char *name) {
    for(CgEnv *e=env;e;e=e->parent) {
        CgBinding *b=cg_binding(e,name);if(b->name)return b->value;
    }
    fprintf(stderr,"bootstrap: undefined binding %s\n",name);exit(1);
}
static Yv *cg_set(CgEnv *env,const char *name,Yv *v) {
    for(CgEnv *e=env;e;e=e->parent) {
        CgBinding *b=cg_binding(e,name);if(b->name)return b->value=v;
    }
    fprintf(stderr,"bootstrap: assignment to undefined binding %s\n",name);exit(1);
}
typedef struct { CgEnv *env; const char *name; ylong *index; } CgRange;
static void cg_range_sync(CgRange *range) {
    *range->index = yv_l(cg_get(range->env, range->name));
}
typedef struct { Yv **value; ylong *index; } CgLocalRange;
static void cg_local_range_sync(CgLocalRange *range) {
    *range->index = yv_l(*range->value);
}
static Yv *cg_func(CgCode code, CgEnv *env, size_t arity) {
    CgClosure *f = malloc(sizeof(*f));
    if (!f) exit(1);
    f->code = code; f->env = env; f->arity=arity; ++env->refs;
    return yv_long((ylong)(intptr_t)f);
}
static Yv *cg_call(Yv *v, size_t n, Yv **args) {
    if(yv_tag(v)!=Y_LONG || yv_l(v)<4096){fputs("bootstrap: called non-function\n",stderr);exit(1);}
    CgClosure *f = (CgClosure *)(intptr_t)yv_l(v);
    return f->code(v, n, args);
}
static Yv *cg_index(Yv *a, Yv *i) {
    return yv_tag(a) == Y_STR ? yv_long(ys_byte_at(a, yv_l(i))) : ya_get(a, yv_l(i));
}
static Yv *cg_bytes(size_t n,Yv **values) {
    Yv *a=ya_bytes_zero((ylong)n);
    for(size_t i=0;i<n;++i)((unsigned char *)a->u.a.items)[i]=(unsigned char)yv_l(values[i]);
    return a;
}
static Yv *cg_bytes_repeat(Yv *value,ylong n) {
    Yv *a=ya_bytes_zero(n);
    if(n>0)memset(a->u.a.items,(unsigned char)yv_l(value),(size_t)n);
    return a;
}
static void cg_spread(Yv *record, Yv *source) {
    if (!source || yv_tag(source) != Y_REC) {
        fputs("bootstrap: spread of non-record\n", stderr);
        exit(1);
    }
    for (size_t i = 0; i < source->u.r.len; ++i)
        yr_set(record, source->u.r.keys[i], source->u.r.vals[i]);
}
static Yv *cg_slice(Yv *a, Yv *lo, Yv *hi) {
    ylong l = yv_is_none(lo) ? 0 : yv_l(lo), h = yv_is_none(hi) ? yv_len(a) : yv_l(hi);
    return yv_tag(a) == Y_STR ? ys_slice(a, l, h) : ya_slice(a, l, h);
}
static Yv *cg_append(Yv *a, Yv *b) {
    if (yv_tag(a) == Y_STR) return ys_cat(a,ys_tostring(b));
    if (yv_tag(a)==Y_FLOAT || yv_tag(b)==Y_FLOAT) return yv_float(yv_f(a)+yv_f(b));
    if (yv_tag(a) != Y_ARR) return yv_long((ylong)((uint64_t)yv_l(a)+(uint64_t)yv_l(b)));
    if (yv_tag(b) == Y_ARR) {
        size_t n = b->u.a.len;
        for (size_t i = 0; i < n; ++i) ya_push(a, ya_get(b,(ylong)i));
    } else ya_push(a, b);
    return a;
}
static int cg_equal(Yv *a, Yv *b) {
    if (yv_tag(a) == Y_FLOAT || yv_tag(b) == Y_FLOAT) return yv_f(a) == yv_f(b);
    if (a == b) return 1;
    if (yv_tag(a) != yv_tag(b)) return 0;
    if (yv_tag(a) == Y_REC) return 0; /* records and maps compare by identity */
    if (yv_tag(a) == Y_STR)
        return a->u.s.n == b->u.s.n && !memcmp(a->u.s.p, b->u.s.p, a->u.s.n);
    if (yv_tag(a) == Y_ARR) {
        if (a->u.a.len != b->u.a.len) return 0;
        for (size_t i = 0; i < a->u.a.len; ++i)
            if (!cg_equal(ya_get(a,(ylong)i), ya_get(b,(ylong)i))) return 0;
        return 1;
    }
    return yv_eq(a, b);
}
typedef enum { CG_EQ,CG_NE,CG_IN,CG_ADD,CG_SUB,CG_MUL,CG_DIV,CG_MOD,
    CG_LT,CG_GT,CG_LE,CG_GE,CG_AND,CG_OR,CG_XOR,CG_SHL,CG_SHR,CG_USHR } CgOp;
static Yv *cg_bin(CgOp op, Yv *a, Yv *b) {
    ylong x = yv_l(a), y = yv_l(b);
    uint64_t ux = (uint64_t)x, uy = (uint64_t)y;
    if (op==CG_EQ) return yv_bool(cg_equal(a,b));
    if (op==CG_NE) return yv_bool(!cg_equal(a,b));
    if (yv_tag(a)==Y_FLOAT || yv_tag(b)==Y_FLOAT) {
        double u=yv_f(a),v=yv_f(b);
        if(op==CG_ADD)return yv_float(u+v);
        if(op==CG_SUB)return yv_float(u-v);
        if(op==CG_MUL)return yv_float(u*v);
        if(op==CG_DIV)return yv_float(u/v);
        if(op==CG_LT)return yv_bool(u<v);
        if(op==CG_GT)return yv_bool(u>v);
        if(op==CG_LE)return yv_bool(u<=v);
        if(op==CG_GE)return yv_bool(u>=v);
    }
    if (op==CG_IN) {
        if (yv_tag(b) == Y_ARR) {
            for (size_t i=0; i<b->u.a.len; ++i) if (cg_equal(a,ya_get(b,(ylong)i))) return yv_bool(1);
            return yv_bool(0);
        }
        return yv_bool(ys_index_of(b,a)>=0);
    }
    if (op==CG_ADD && (yv_tag(a)==Y_STR || yv_tag(b)==Y_STR)) return ys_cat(ys_tostring(a),ys_tostring(b));
    if (yv_tag(a) == Y_STR && yv_tag(b) == Y_STR) {
        x = ys_cmp(a,b); y = 0;
    }
    if (op==CG_LT) return yv_bool(x<y);
    if (op==CG_GT) return yv_bool(x>y);
    if (op==CG_LE) return yv_bool(x<=y);
    if (op==CG_GE) return yv_bool(x>=y);
    if (op==CG_ADD) {
        if (yv_tag(a) == Y_ARR) return cg_append(ya_slice(a,0,yv_len(a)),b);
        return yv_long((ylong)(ux+uy));
    }
    if (op==CG_SUB) return yv_long((ylong)(ux-uy));
    if (op==CG_MUL) return yv_long((ylong)(ux*uy));
    if (op==CG_DIV) { if (!y) exit(1); return yv_long(x==INT64_MIN && y==-1 ? x : x/y); }
    if (op==CG_MOD) { if (!y) exit(1); return yv_long(x==INT64_MIN && y==-1 ? 0 : x%y); }
    if (op==CG_AND) return yv_long(x&y);
    if (op==CG_OR) return yv_long(x|y);
    if (op==CG_XOR) return yv_long(x^y);
    if (op==CG_SHL) { if(y<0)exit(1); return yv_long(y>=64 ? 0 : (ylong)(ux<<y)); }
    if (op==CG_SHR) { if(y<0)exit(1); return yv_long(y>=64 ? (x<0?-1:0) : x>>y); }
    if (op==CG_USHR) { if(y<0)exit(1); return yv_long(y>=64 ? 0 : (ylong)(ux>>y)); }
    fputs("bootstrap: unsupported operator\n",stderr); exit(1);
}
static Yv *cg_un(const char *op, Yv *a) {
    if (!strcmp(op,"!")) return yv_bool(!yv_truth(a));
    if (!strcmp(op,"-") && yv_tag(a)==Y_FLOAT) return yv_float(-yv_f(a));
    if (!strcmp(op,"-")) return yv_long((ylong)(0-(uint64_t)yv_l(a)));
    if (!strcmp(op,"~")) return yv_long(~yv_l(a));
    if (!strcmp(op,"+")) return a;
    fprintf(stderr,"bootstrap: unsupported unary operator %s\n",op);exit(1);
}

#include <unistd.h>
#include <errno.h>
#ifdef _WIN32
static Yv *cg_exec(Yv *command) {
    return yv_long((ylong)_spawnlp(_P_WAIT,"cmd.exe","cmd.exe","/d","/s","/c",command->u.s.p,NULL));
}
#else
#include <sys/wait.h>
static Yv *cg_exec(Yv *command) {
    pid_t pid = fork();
    if (pid < 0) return yv_long(-1);
    if (pid == 0) {
        char *args[] = {"/bin/sh", "-c", command->u.s.p, NULL};
        char *environment[] = {NULL};
        execve(args[0], args, environment);
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return yv_long(-1);
    }
    return yv_long(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
}
#endif
typedef struct CgBuffer { Yv *array; unsigned char *data; size_t n, stride; struct CgBuffer *next; } CgBuffer;
static CgBuffer *cg_buffers;
static void cg_buffer_copy(CgBuffer *p, int from_kernel) {
    for (size_t i=0;i<p->n;++i) {
        if (from_kernel) {
            uint64_t v=0; memcpy(&v,p->data+i*p->stride,p->stride);
            if (yv_l(ya_get(p->array,(ylong)i)) != (ylong)v) ya_set(p->array,(ylong)i,yv_long((ylong)v));
        } else {
            uint64_t v=(uint64_t)yv_l(ya_get(p->array,(ylong)i));
            memcpy(p->data+i*p->stride,&v,p->stride);
        }
    }
}
static Yv *cg_address(Yv *array, Yv *index, size_t stride) {
    if(yv_tag(array)==Y_ARR && array->u.a.bytewise==2)
        return yv_long((ylong)(intptr_t)((unsigned char *)array->u.a.items+yv_l(index)));
    if(yv_tag(array)==Y_ARR && array->u.a.bytewise)stride=1;
    CgBuffer *p=cg_buffers;
    while(p && p->array!=array)p=p->next;
    if(!p) {
        p=calloc(1,sizeof(*p)); if(!p)exit(1);
        p->array=array;p->stride=stride;p->n=(size_t)yv_len(array);
        p->data=calloc(p->n?p->n:1,stride);if(!p->data)exit(1);
        p->next=cg_buffers;cg_buffers=p;
    }
    if(p->n!=(size_t)yv_len(array)){fputs("bootstrap: array grew after address was taken\n",stderr);exit(1);}
    cg_buffer_copy(p,0);
    return yv_long((ylong)(intptr_t)(p->data+yv_l(index)*stride));
}
static Yv *cg_copy_fwd(Yv *dst,Yv *src,Yv *count) {
    unsigned char *d=(unsigned char *)(intptr_t)yv_l(dst);
    const unsigned char *s=(const unsigned char *)(intptr_t)yv_l(src);
    for(CgBuffer *p=cg_buffers;p;p=p->next) {
        uintptr_t lo=(uintptr_t)p->data,hi=lo+p->n*p->stride;
        if(((uintptr_t)d>=lo && (uintptr_t)d<hi) || ((uintptr_t)s>=lo && (uintptr_t)s<hi))cg_buffer_copy(p,0);
    }
    for(ylong i=0;i<yv_l(count);++i)d[i]=s[i];
    for(CgBuffer *p=cg_buffers;p;p=p->next)
        if((uintptr_t)d>=(uintptr_t)p->data && (uintptr_t)d<(uintptr_t)p->data+p->n*p->stride)cg_buffer_copy(p,1);
    return yv_long(0);
}
static Yv *cg_syscall(size_t n,Yv **args) {
    ylong a[7]={0};
    if(n>7)exit(1);
    for(size_t i=0;i<n;++i) a[i]=yv_tag(args[i])==Y_STR?(ylong)(intptr_t)args[i]->u.s.p:yv_l(args[i]);
    for(CgBuffer *p=cg_buffers;p;p=p->next)cg_buffer_copy(p,0);
    errno=0;
#ifdef _WIN32
    ylong r=syscall(a[0],a[1],a[2],a[3],a[4],a[5],a[6]);
#else
    ylong r=a[0]==(cg_host_machine()==183 ? 220 : 57) ? (ylong)fork() : syscall(a[0],a[1],a[2],a[3],a[4],a[5],a[6]);
#endif
    if(r==-1)r=-errno;
    for(CgBuffer *p=cg_buffers;p;p=p->next)cg_buffer_copy(p,1);
    return yv_long((ylong)r);
}
/* Modes: foreach, some, all, map, filter. Re-read length after callbacks. */
static Yv *cg_iter(Yv *array,Yv *callback,int mode) {
    CgClosure *f=(CgClosure *)(intptr_t)yv_l(callback);
    Yv *out=mode>=3?yav(0):yv_none();
    for(ylong i=0;i<yv_len(array);++i) {
        Yv *value=cg_index(array,yv_long(i));
        Yv *args[2]={value,yv_long(i)};
        Yv *r=cg_call(callback,f->arity,args);
        if(mode==1 && yv_truth(r))return yv_bool(1);
        if(mode==2 && !yv_truth(r))return yv_bool(0);
        if(mode==3 || (mode==4 && yv_truth(r)))ya_push(out,mode==3?r:value);
    }
    return mode==1 || mode==2 ? yv_bool(mode==2) : out;
}
static Yv *cg_sort(Yv *array,Yv *callback,int copy) {
    Yv *out=copy?ya_slice(array,0,yv_len(array)):array;
    for(ylong i=1;i<yv_len(out);++i) {
        Yv *key=cg_index(out,yv_long(i));
        ylong j=i-1;
        while(j>=0) {
            Yv *prev=cg_index(out,yv_long(j));
            Yv *args[2]={prev,key};
            if(yv_l(cg_call(callback,2,args))<=0)break;
            ya_set(out,j+1,prev);
            --j;
        }
        ya_set(out,j+1,key);
    }
    return copy?out:yv_none();
}
static Yv *cg_pop(Yv *a) {
    if(yv_tag(a)!=Y_ARR || a->u.a.len==0){fputs("bootstrap: pop of empty array\n",stderr);exit(1);}
    Yv *v=ya_get(a,(ylong)a->u.a.len-1);--a->u.a.len;return v;
}
static Yv *cg_reduce(Yv *a,Yv *callback,Yv *value) {
    CgClosure *f=(CgClosure *)(intptr_t)yv_l(callback);
    for(ylong i=0;i<yv_len(a);++i){Yv *args[3]={value,cg_index(a,yv_long(i)),yv_long(i)};value=cg_call(callback,f->arity,args);}
    return value;
}
static Yv *cg_find(Yv *a,Yv *v) {
    for(ylong i=0;i<yv_len(a);++i)if(cg_equal(cg_index(a,yv_long(i)),v))return yv_long(i);
    return yv_long(-1);
}
