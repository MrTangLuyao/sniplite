/* The few C library functions the C modules use or the compiler emits calls to:
 * the program links no C runtime (build.bat: -nostdlib). */
#include <stddef.h>
#include <wchar.h>

void *memcpy(void *restrict d, const void *restrict s, size_t n)
{
    void *r = d;
    __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
    return r;
}

void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *dp = d;
    const unsigned char *sp = s;
    if (dp <= sp || dp >= sp + n)
        return memcpy(d, s, n);
    dp += n - 1;
    sp += n - 1;
    __asm__ volatile("std\n\trep movsb\n\tcld" : "+D"(dp), "+S"(sp), "+c"(n) : : "memory");
    return d;
}

void *memset(void *d, int c, size_t n)
{
    void *r = d;
    __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(c) : "memory");
    return r;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = a, *q = b;
    for (; n; n--, p++, q++)
        if (*p != *q)
            return *p - *q;
    return 0;
}

wchar_t *wcschr(const wchar_t *s, wchar_t c)
{
    for (;; s++) {
        if (*s == c)
            return (wchar_t *)s;
        if (!*s)
            return NULL;
    }
}

wchar_t *wcsrchr(const wchar_t *s, wchar_t c)
{
    const wchar_t *r = NULL;
    for (;; s++) {
        if (*s == c)
            r = s;
        if (!*s)
            return (wchar_t *)r;
    }
}

size_t wcslen(const wchar_t *s)
{
    const wchar_t *e = s;
    while (*e)
        e++;
    return (size_t)(e - s);
}

int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n)
{
    for (; n; n--, a++, b++)
        if (*a != *b || !*a)
            return (int)*a - (int)*b;
    return 0;
}

wchar_t *wcsstr(const wchar_t *s, const wchar_t *t)
{
    if (!*t)
        return (wchar_t *)s;
    for (; *s; s++) {
        const wchar_t *a = s, *b = t;
        while (*a && *a == *b)
            a++, b++;
        if (!*b)
            return (wchar_t *)s;
    }
    return NULL;
}

/* ---- the little arithmetic pin.c asks the library for; values are finite here ---- */

/* Round half away from zero. The largest float below one half is added, so that a
 * value just under .5 is not carried up by the addition: x + 0.5f would turn
 * 0.49999997f into 1. */
long lroundf(float x)
{
    return (long)(x + (x < 0 ? -0.49999997f : 0.49999997f));
}

float fminf(float a, float b) { return a < b ? a : b; }
float fmaxf(float a, float b) { return a > b ? a : b; }
