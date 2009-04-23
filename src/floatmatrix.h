#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/intext.h>

struct matrix {
    int size;       /* current maximum size of array */
    int loc;        /* current portion used */
    double *mat;    /* data */
};
typedef struct matrix mat;

void floatmatrix_CAML_free_floatmatrix( value v );
int  floatmatrix_CAML_compare( value one,value two );
void floatmatrix_CAML_serialize(value v, unsigned long* wsize_32, unsigned long* wsize_64);
unsigned long floatmatrix_CAML_deserialize( void* dst );
value floatmatrix_CAML_register (value u);

/* void expand_matrix( mat* m, int s ); */
void  clear_subsection( mat* m, int l, int h );
double* register_section (mat* m, int s, int c ); /* registers section and returns ptr */
void  free_all (mat* m);
