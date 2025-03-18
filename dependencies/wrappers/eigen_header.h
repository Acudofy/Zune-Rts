#ifndef EIGEN_WRAPPER_H
#define EIGEN_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// Matrix operations
void eigen_mat4_inverse(const float* in, float* out);
void eigen_mat4_multiply(const float* a, const float* b, float* out);
void eigen_mat4_ldlt_solve(const float* A, const float* b, float* x);
void eigen_mat4_pinverse(const float* in, float* out);
void eigen_mat4_robust_inverse(const float* in, float* out);
void eigen_mat4d_robust_inverse(const double* in, double* out);


// Vector operations
void eigen_vec4_multiply(const float* mat, const float* vec, float* out);
void eigen_vec4d_multiply(const double* mat, const double* vec, double* out);
void eigen_vec3_cross(const float* a, const float* b, float* out);
// Add more function declarations as needed

#ifdef __cplusplus
}
#endif

#endif // EIGEN_WRAPPER_H