#include <Eigen/Dense>
#include <cstdint>
#include <iostream>
using namespace std;


extern "C" {
    // Matrix operations
    void eigen_mat4_inverse(const float* in, float* out) {
        Eigen::Map<const Eigen::Matrix4f> inMat(in);
        Eigen::Map<Eigen::Matrix4f> outMat(out);
        outMat = inMat.inverse();
    }

    
    void eigen_mat4_ldlt_solve(const float* A, const float* b, float* x) {
        Eigen::Map<const Eigen::Matrix4f> matA(A);
        Eigen::Map<const Eigen::Vector4f> vecB(b);
        Eigen::Map<Eigen::Vector4f> vecX(x);

        Eigen::LDLT<Eigen::Matrix4f> ldlt(matA);
        vecX = ldlt.solve(vecB);
    }
    

    void eigen_mat4_multiply(const float* a, const float* b, float* out) {
        Eigen::Map<const Eigen::Matrix4f> matA(a);
        Eigen::Map<const Eigen::Matrix4f> matB(b);
        Eigen::Map<Eigen::Matrix4f> outMat(out);
        outMat = matA * matB;
    }
    
    // Vector operations
    void eigen_vec4_multiply(const float* mat, const float* vec, float* out) {
        Eigen::Map<const Eigen::Matrix4f> matrix(mat);
        Eigen::Map<const Eigen::Vector4f> vector(vec);
        Eigen::Map<Eigen::Vector4f> result(out);
        result = matrix * vector;
    }

    void eigen_vec4d_multiply(const double* mat, const double* vec, double* out) {
        Eigen::Map<const Eigen::Matrix4d> matrix(mat);
        Eigen::Map<const Eigen::Vector4d> vector(vec);
        Eigen::Map<Eigen::Vector4d> result(out);
        result = matrix * vector;
    }

    void eigen_vec3_cross(const float* a, const float* b, float* out) {
        Eigen::Map<const Eigen::Vector3f> vecA(a);
        Eigen::Map<const Eigen::Vector3f> vecB(b);
        Eigen::Map<Eigen::Vector3f> result(out);
        result = vecA.cross(vecB);
    }

    void eigen_mat4_pinverse(const float* in, float* out) {
        Eigen::Map<const Eigen::Matrix4f> inMat(in);
        Eigen::Map<Eigen::Matrix4f> outMat(out);
        outMat = inMat.completeOrthogonalDecomposition().pseudoInverse();
    }

    void eigen_mat4_robust_inverse(const float* in, float* out) {
        Eigen::Map<const Eigen::Matrix4f> inMat(in);
        Eigen::Map<Eigen::Matrix4f> outMat(out);
        
        // bool invertible;
        
        // Use the specialized function for matrices up to 4×4
        // float determinant = inMat.determinant();
        
        Eigen::FullPivLU<Eigen::Matrix4f> lu(inMat);
        bool invertible = lu.isInvertible();
        
        if (invertible) {

            outMat = inMat.inverse();
        } else {
            cout << "Singular:\n";
            cout << inMat;
            cout << "\n\n";
            // Matrix is singular, use pseudo-inverse
            outMat = inMat.completeOrthogonalDecomposition().pseudoInverse();
        }
    }

    void eigen_mat4d_robust_inverse(const double* in, double* out) {
        Eigen::Map<const Eigen::Matrix4d> inMat(in);
        Eigen::Map<Eigen::Matrix4d> outMat(out);
        
        Eigen::Matrix4d inverse;
        bool invertible;
        
        // Use the specialized function for matrices up to 4×4
        float det = inMat.determinant();
        // inMat.computeInverseWithCheck(inverse, invertible);
        
        if (abs(det) > pow(10, -2)) {
            // cout << "Invertible!\n";
            
            inverse = inMat.inverse();
            
            // cout << "\n\n==================\n";
            // cout << inverse;
            // cout << "\n------------------\n";
            // cout << inMat.completeOrthogonalDecomposition().pseudoInverse();

            outMat = inverse;
        } else {
            // cout << "Singular!\n";
            // Matrix is singular, use pseudo-inverse
            outMat = inMat.completeOrthogonalDecomposition().pseudoInverse();
        }
    }
    
    // Add more functions as needed
}