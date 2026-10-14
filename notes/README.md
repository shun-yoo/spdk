# 공부 노트

SPDK를 공부하면서 정리한 내용. 위에서부터 읽는다.

1. [spdk-overview.md](spdk-overview.md): SPDK가 뭔가, 직접 제어·bdev·네트워크 구성
2. [nvme-of.md](nvme-of.md): 네트워크 부분. 타겟과 이니시에이터, 컨트롤러, 큐, 읽기 한 번이 오가는 모양
3. [initiator-flow.md](initiator-flow.md): SPDK 이니시에이터의 코드 흐름. I/O 큐 하나 연결, 읽기 한 번
