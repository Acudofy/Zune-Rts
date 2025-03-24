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
            cout << "Singular!";
            // Matrix is singular, use pseudo-inverse
            outMat = inMat.completeOrthogonalDecomposition().pseudoInverse();
        }
    }

    bool eigen_optimal_vertex_revised(const double* Q, const double* v0, double lambda, double* v_out) {
        if (!Q || !v0 || !v_out) {
            return 0; // Invalid pointers
        }
    
        // Map the input array Q to an Eigen 4x4 matrix (column-major)
        Eigen::Map<const Eigen::Matrix<double, 4, 4>> quadric(Q);
        
        // Extract the 3x3 upper-left block of the quadric
        Eigen::Matrix3d A = quadric.block<3, 3>(0, 0);
        
        // Extract the translation part (first 3 elements of the last column)
        Eigen::Vector3d b = quadric.block<3, 1>(0, 3);
        
        // Map the input reference vector v0 as a 3D vector
        Eigen::Map<const Eigen::Vector3d> ref(v0);
        
        // Add regularization: A + lambda*I
        Eigen::Matrix3d regularized_A = A;
        for (int i = 0; i < 3; i++) {
            regularized_A(i, i) += lambda;
        }
        
        // Solve for the optimal position: (A + lambda*I)v = b + lambda*v0
        Eigen::Vector3d rhs = -b + lambda * ref;
        
        // Use a robust solver
        Eigen::BDCSVD<Eigen::Matrix3d> solver(regularized_A, Eigen::ComputeFullU | Eigen::ComputeFullV);
        Eigen::Vector3d v_opt = solver.solve(rhs);
        
        // Write the solution to v_out
        v_out[0] = v_opt(0);
        v_out[1] = v_opt(1);
        v_out[2] = v_opt(2);
        v_out[3] = 1.0;
        
        return 1;
    }

    bool eigen_optimal_vertex(const double* Q, const double* v0, double lambda, double* v_out) {
        if (!Q || !v0 || !v_out) {
            return 0; // Invalid pointers
        }
    
        // Map the input array Q to an Eigen 4x4 matrix (column-major)
        Eigen::Map<const Eigen::Matrix<double, 4, 4>> quadric(Q);
        
        // Map the input reference vector v0 as a 3D vector
        Eigen::Map<const Eigen::Vector3d> ref(v0);
        
        // Construct the modified matrix: Q + lambda * I
        Eigen::Matrix4d modQ = quadric;
        
        // Only apply regularization to the 3x3 upper-left block (spatial components)
        for (int i = 0; i < 3; i++) {
            modQ(i, i) += lambda;
        }
    
        // Form the right-hand side: lambda * v0 (extended to homogeneous coordinates)
        Eigen::Vector4d rhs;
        rhs << lambda * v0[0], lambda * v0[1], lambda * v0[2], 1.0;
        
        // Constrain the solution to be a valid homogeneous point
        // by setting the last row to [0,0,0,1]
        modQ.row(3) = Eigen::Vector4d(0, 0, 0, 1);
        rhs(3) = 1.0;
        
        // Solve using full pivot LU for robustness
        Eigen::FullPivLU<Eigen::Matrix4d> solver(modQ);
        // cout << "\nAx = b\n";
        // cout << modQ;
        // cout << "*x = ";
        // cout << rhs;
        // cout << "\n";
        
        if (!solver.isInvertible()) {
            // Fallback: use v0 as the solution if system is not solvable
            v_out[0] = v0[0];
            v_out[1] = v0[1];
            v_out[2] = v0[2];
            v_out[3] = 1.0;
            return 0;
        }
        
        Eigen::Vector4d v_opt = solver.solve(rhs);
        
        // Normalize to ensure w=1 (proper homogeneous coordinates)
        if (std::abs(v_opt(3)) > 1e-10) {  // Avoid division by near-zero
            v_opt /= v_opt(3);
        } else {
            // If w is near zero, use v0 as fallback
            v_out[0] = v0[0];
            v_out[1] = v0[1];
            v_out[2] = v0[2];
            v_out[3] = 1.0;
            return 0;
        }
        
        // Write the solution to v_out
        for (int i = 0; i < 4; i++) {
            v_out[i] = v_opt(i);
        }

        // cout << "v_opt:\n";
        // cout << v_opt;
        
        return 1;
    }    
    // Add more functions as needed
}