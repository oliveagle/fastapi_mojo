# src/fastapi_mojo/tcp_server.mojo
#
# 测试 Mojo C FFI 实现 TCP server

from std.ffi import external_call


def main():
    print("Testing Mojo C FFI TCP server...")
    
    # 创建 socket
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
    
    print("TCP server test completed!")
