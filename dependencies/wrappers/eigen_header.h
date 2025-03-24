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

// Custom functions

// Computes the optimal vertex position for an edge collapse with bias.
// Q is a pointer to a 4x4 matrix (row-major) representing the quadric error.
// v0 is a pointer to a 4x1 vector (homogeneous coordinates) representing the reference position.
// lambda is the bias weight.
// The computed optimal vertex is written to v_out (a 4x1 vector, in homogeneous coordinates).
// Returns true on success, false on failure.
int eigen_optimal_vertex(const double* Q, const double* v0, double lambda, double* v_out);
int eigen_optimal_vertex_revised(const double* Q, const double* v0, double lambda, double* v_out);

#ifdef __cplusplus
}
#endif

#endif // EIGEN_WRAPPER_H