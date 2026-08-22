# src/fastapi_mojo/ffi_test.mojo
#
# 测试 Mojo C FFI 功能：调用 C socket 库函数

from std.ffi import external_call


def main():
    print("Testing Mojo C FFI socket...")
    
    # 测试 socket 函数
    var AF_INET = 2
    var SOCK_STREAM = 1
    var sockfd = external_call["socket", Int](AF_INET, SOCK_STREAM, 0)
    print("socket returned: " + String(sockfd))
    
    if sockfd >= 0:
        print("Socket created successfully!")
        
        # 测试 close 函数
        var close_result = external_call["close", Int](sockfd)
        print("close returned: " + String(close_result))
    else:
        print("Socket creation failed!")
    
    print("C FFI socket test completed!")
