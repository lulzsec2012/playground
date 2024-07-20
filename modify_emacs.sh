#!/bin/bash

# 文件路径
BASE_PATH="~/.emacs.d/elpa/symon-"

# 通配符匹配不确定的时间部分
FILE1="${BASE_PATH}*/symon.el"
FILE2="${BASE_PATH}*/symon.elc"


# 不存在匹配的文件则退出
if [ ! -f $FILE2 ]; then
  echo "File ${FILE2} not exist!"
  exit 0
fi

# 获取文件的创建时间（以纪元秒为单位）
TIME1=$(stat -c %W $FILE1 2>/dev/null || stat -c %Y $FILE1)
TIME2=$(stat -c %W $FILE2 2>/dev/null || stat -c %Y $FILE2)

# 检查是否成功获取到创建时间
if [ "$TIME1" -eq "-1" ] || [ "$TIME2" -eq "-1" ]; then
  echo "One or both files do not support creation time. Falling back to modification time."
  # 获取文件的修改时间（以纪元秒为单位）
  TIME1=$(stat -c %Y $FILE1)
  TIME2=$(stat -c %Y $FILE2)
fi

# 比较文件创建时间
echo $TIME1
echo $TIME2
if [ "$TIME1" -eq "$TIME2" ]; then
  echo "The creation time of $FILE1 and $FILE2 is the same. Deleting $FILE2."
  rm $FILE2
  if [ $? -eq 0 ]; then
    echo "Successfully deleted $FILE2."
  else
    echo "Failed to delete $FILE2."
  fi
else
  echo "The creation time of $FILE1 and $FILE2 is different."
fi
